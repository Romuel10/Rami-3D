#!/usr/bin/env python3
"""Real WebSocket regressions for lobby departures and authoritative forfeits."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from test_internet import Client, GODOT, PROJECT


class Server:
    def __init__(self, grace=60000, state_file=None, port=None):
        if port is None:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
        self.port = port
        self.grace = grace
        self.state_file = state_file
        self.process = None
        self.log = tempfile.TemporaryFile(mode="w+")

    def start(self):
        arguments = [GODOT, "--headless", "--path", str(PROJECT), "--script", "server/server.gd", "--", f"--port={self.port}", f"--reconnect-grace-ms={self.grace}"]
        if self.state_file is not None:
            arguments.append(f"--state-file={self.state_file}")
        self.process = subprocess.Popen(arguments, stdout=self.log, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 7
        while time.monotonic() < deadline:
            self.log.seek(0)
            output = self.log.read()
            if "RAMI_SERVER_READY" in output:
                return self
            if self.process.poll() is not None:
                raise AssertionError("Server startup failed:\n" + output)
            time.sleep(0.015)
        raise AssertionError("Server readiness timed out")

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=4)
            self.process = None
        self.log.seek(0)
        output = self.log.read()
        assert "SCRIPT ERROR" not in output and "Parse Error" not in output, output
        self.log.seek(0)
        self.log.truncate()

    def __enter__(self):
        return self.start()

    def __exit__(self, *_args):
        self.stop()
        self.log.close()


def create(server, name="Alice"):
    client = Client(server.port)
    client.send({"type": "create", "name": name})
    welcome = client.until("welcome")
    client.until("lobby")
    return client, welcome


def join(server, code, name="Bob", token=None):
    client = Client(server.port)
    message = {"type": "join", "code": code, "name": name}
    if token is not None:
        message["token"] = token
    client.send(message)
    welcome = client.until("welcome")
    client.until("lobby")
    return client, welcome


def start(host, clients):
    host.send({"type": "start"})
    return [client.until("state")["data"] for client in clients]


def close_all(clients):
    for client in clients:
        try:
            client.close()
        except OSError:
            pass


def lobby_regression():
    clients = []
    with Server() as server:
        try:
            a, aw = create(server); clients.append(a)
            b, bw = join(server, aw["code"]); clients.append(b)
            a.until("lobby", lambda value: len(value["data"]["players"]) == 2)
            b.send({"type": "leave"})
            a.until("welcome", lambda value: value["player"] == 0)
            lobby = a.until("lobby", lambda value: len(value["data"]["players"]) == 1)["data"]
            assert [player["name"] for player in lobby["players"]] == ["Alice"]
            c, cw = join(server, aw["code"], "Chloe"); clients.append(c)
            assert cw["player"] == 1
            state_a, state_c = start(a, [a, c])
            assert not state_a["paused"] and len(state_c["hand"]) == 13
        finally:
            close_all(clients)
    # Dropped host before a deal transfers ownership and leaves no ghost seat.
    clients = []
    with Server() as server:
        try:
            a, aw = create(server); clients.append(a)
            b, bw = join(server, aw["code"]); clients.append(b)
            a.close()
            shifted = b.until("welcome", lambda value: value["player"] == 0)
            assert shifted["is_host"] and shifted["token"] == bw["token"]
            b.until("lobby", lambda value: len(value["data"]["players"]) == 1)
            c, cw = join(server, aw["code"], "Chloe"); clients.append(c)
            assert cw["player"] == 1
            assert not start(b, [b, c])[0]["paused"]
        finally:
            close_all(clients)


def voluntary_forfeit():
    # Claiming another player's index in the packet must forfeit the sender only.
    clients = []
    with Server() as server:
        try:
            a, aw = create(server); clients.append(a)
            b, bw = join(server, aw["code"]); clients.append(b)
            before_a, before_b = start(a, [a, b])
            b.send({"type": "leave", "player": 0})
            own = b.until("state", lambda value: value["data"]["winner"] == 0)["data"]
            won = a.until("state", lambda value: value["data"]["winner"] == 0)["data"]
            assert own["players"][1]["forfeited"] and not own["players"][0]["forfeited"]
            assert won["win_by_forfeit"] and not won["paused"]
            assert won["hand"] == before_a["hand"] and own["hand"] == before_b["hand"]
            assert won["match_result"]["winners"] == [0]
            assert all("token" not in player and "hand" not in player for player in won["players"])
            lost = Client(server.port); clients.append(lost)
            lost.send({"type": "join", "code": aw["code"], "token": bw["token"]})
            rejected = lost.until("state")["data"]
            assert rejected["your_index"] == 1 and rejected["players"][1]["forfeited"]
            assert lost.until("error")["fatal"]
        finally:
            close_all(clients)
    # Leaving the owner of a dedicated room cannot stop the other player winning.
    clients = []
    with Server() as server:
        try:
            a, aw = create(server); clients.append(a)
            b, _ = join(server, aw["code"]); clients.append(b)
            start(a, [a, b])
            a.send({"type": "leave"})
            won = b.until("state", lambda value: value["data"]["winner"] == 1)["data"]
            assert won["players"][0]["forfeited"] and won["win_by_forfeit"] and not won["paused"]
        finally:
            close_all(clients)


def grace_and_elimination():
    clients = []
    with Server(grace=900) as server:
        try:
            a, aw = create(server); clients.append(a)
            b, bw = join(server, aw["code"]); clients.append(b)
            initial_a, initial_b = start(a, [a, b])
            b.close()
            paused = a.until("state", lambda value: value["data"]["paused"])["data"]
            assert 0 < paused["reconnect_remaining_ms"] <= 900
            b2, bw2 = join(server, aw["code"], token=bw["token"]); clients.append(b2)
            resumed = b2.until("state")["data"]
            assert resumed["hand"] == initial_b["hand"] and not resumed["paused"]
            a.until("state", lambda value: not value["data"]["paused"])
            b2.close()
            a.until("state", lambda value: value["data"]["paused"])
            won = a.until("state", lambda value: value["data"]["winner"] == 0)["data"]
            assert won["win_by_forfeit"] and not won["paused"] and won["hand"] == initial_a["hand"]
        finally:
            close_all(clients)
    clients = []
    with Server() as server:
        try:
            a, aw = create(server); clients.append(a)
            b, _ = join(server, aw["code"]); clients.append(b)
            c, _ = join(server, aw["code"], "Chloe"); clients.append(c)
            states = start(a, [a, b, c])
            a.send({"type": "leave"})
            playing = b.until("state", lambda value: value["data"]["players"][0]["forfeited"])["data"]
            assert playing["winner"] == -1 and playing["turn"] == 1 and not playing["paused"]
            b.send({"type": "action", "action": {"type": "draw", "source": "deck"}})
            drawn = b.until("state", lambda value: value["data"]["phase"] == "play")["data"]
            assert len(drawn["hand"]) == 14
            b.send({"type": "leave"})
            won = c.until("state", lambda value: value["data"]["winner"] == 2)["data"]
            assert [player["forfeited"] for player in won["players"]] == [True, True, False]
            assert not won["paused"] and won["win_by_forfeit"]
            assert won["hand"] == states[2]["hand"]
        finally:
            close_all(clients)


def four_player_elimination():
    clients = []
    with Server() as server:
        try:
            a, aw = create(server); clients.append(a)
            b, _ = join(server, aw["code"]); clients.append(b)
            c, _ = join(server, aw["code"], "Chloe"); clients.append(c)
            d, _ = join(server, aw["code"], "David"); clients.append(d)
            initial = start(a, [a, b, c, d])
            # Eliminating a different seat leaves the current turn untouched.
            b.send({"type": "leave"})
            playing = a.until("state", lambda value: value["data"]["players"][1]["forfeited"])["data"]
            assert playing["winner"] == -1 and playing["turn"] == 0 and not playing["paused"]
            a.send({"type": "action", "action": {"type": "draw", "source": "deck"}})
            drawn = a.until("state", lambda value: value["data"]["phase"] == "play")["data"]
            time.sleep(0.06)
            a.send({"type": "action", "action": {"type": "discard", "card": drawn["hand"][-1]}})
            skipped = a.until("state", lambda value: value["data"]["turn"] == 2)["data"]
            assert skipped["winner"] == -1 and skipped["hand"] == initial[0]["hand"]
            # Eliminating the current seat advances to the next active player.
            c.send({"type": "leave"})
            advanced = d.until("state", lambda value: value["data"]["players"][2]["forfeited"])["data"]
            assert advanced["winner"] == -1 and advanced["turn"] == 3 and not advanced["paused"]
            d.send({"type": "leave"})
            won = a.until("state", lambda value: value["data"]["winner"] == 0)["data"]
            assert [player["forfeited"] for player in won["players"]] == [False, True, True, True]
            assert won["win_by_forfeit"] and won["match_result"]["winners"] == [0] and not won["paused"]
        finally:
            close_all(clients)


def main():
    lobby_regression()
    voluntary_forfeit()
    grace_and_elimination()
    four_player_elimination()
    print("PASS forfeit server: lobby replacement/ownership, sender-only voluntary leave, owner departure, grace/reconnect/timeout, three/four-player elimination")


if __name__ == "__main__":
    main()
