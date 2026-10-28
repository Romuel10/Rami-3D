#!/usr/bin/env python3
"""Persisted private rooms survive a real dedicated-process restart."""
import json
import os
from pathlib import Path
import tempfile
import time

from test_internet import Client
from test_forfeit_server import Server, create, join, start, close_all


def inventory(game):
    state = game["state"]
    cards = list(state["deck"]) + list(state["discard"])
    for player in state["players"]:
        cards += player["hand"]
    for meld in state["melds"]:
        cards += meld["cards"]
    assert len(cards) == 108 and len(set(cards)) == 108
    return cards


def main():
    with tempfile.TemporaryDirectory(prefix="rami-server-state-") as directory:
        state_path = Path(directory) / "private" / "rooms.json"
        clients = []
        server = Server(grace=2500, state_file=state_path).start()
        try:
            a, aw = create(server); clients.append(a)
            b, bw = join(server, aw["code"]); clients.append(b)
            before_a, before_b = start(a, [a, b])
            a.send({"type": "action", "action": {"type": "draw", "source": "deck"}})
            before_drawn = a.until("state", lambda value: value["data"]["phase"] == "play")["data"]
            assert len(before_drawn["hand"]) == 14
            saved = json.loads(state_path.read_text())
            assert len(saved["rooms"]) == 1
            record = saved["rooms"][0]
            assert record["code"] == aw["code"]
            assert [player["token"] for player in record["players"]] == [aw["token"], bw["token"]]
            inventory(record["game"])
            if os.name == "posix":
                assert state_path.stat().st_mode & 0o077 == 0
            port = server.port
            server.stop()
            close_all(clients)
            clients = []
            server = Server(grace=2500, state_file=state_path, port=port).start()
            resumed_a, _ = join(server, aw["code"], token=aw["token"]); clients.append(resumed_a)
            first = resumed_a.until("state")["data"]
            assert first["hand"] == before_drawn["hand"] and first["phase"] == "play"
            assert first["paused"] and first["reconnect_remaining_ms"] > 0
            resumed_b, _ = join(server, aw["code"], token=bw["token"]); clients.append(resumed_b)
            second = resumed_b.until("state")["data"]
            assert second["hand"] == before_b["hand"] and not second["paused"]
            active = resumed_a.until("state", lambda value: not value["data"]["paused"])["data"]
            assert active["turn"] == before_drawn["turn"] and active["phase"] == "play"
            assert active["deck_count"] == before_drawn["deck_count"]
            assert active["revision"] == before_drawn["revision"]
            # Keep all108cards and the terminal result when the loser leaves.
            resumed_b.send({"type": "leave"})
            won = resumed_a.until("state", lambda value: value["data"]["winner"] == 0)["data"]
            assert won["win_by_forfeit"] and not won["paused"]
            saved = json.loads(state_path.read_text())
            inventory(saved["rooms"][0]["game"])
            assert saved["rooms"][0]["game"]["state"]["players"][1]["forfeited"]
            server.stop()
            close_all(clients)
            clients = []
            server = Server(grace=2500, state_file=state_path, port=port).start()
            final_a, _ = join(server, aw["code"], token=aw["token"]); clients.append(final_a)
            final = final_a.until("state")["data"]
            assert final["winner"] == 0 and final["win_by_forfeit"] and not final["paused"]
            assert final["hand"] == before_drawn["hand"]
            assert final["match_result"]["winners"] == [0]
            lost = Client(port); clients.append(lost)
            lost.send({"type": "join", "code": aw["code"], "token": bw["token"]})
            assert lost.until("state")["data"]["players"][1]["forfeited"]
            assert lost.until("error")["fatal"]
            server.stop()
            close_all(clients)
            clients = []
            # A broken latest file recovers the previous valid atomic snapshot.
            state_path.write_text("{interrupted write")
            server = Server(grace=2500, state_file=state_path, port=port).start()
            recovered, _ = join(server, aw["code"], token=aw["token"]); clients.append(recovered)
            recovered_state = recovered.until("state")["data"]
            assert recovered_state["winner"] == 0 and recovered_state["hand"] == before_drawn["hand"]
            server.stop()
            close_all(clients)
            clients = []
            # Corrupt/duplicated inventory without a good backup cannot create a room.
            backup_path = Path(str(state_path) + ".bak")
            record = json.loads(backup_path.read_text())
            hand = record["rooms"][0]["game"]["state"]["players"][0]["hand"]
            hand[0] = hand[1]
            state_path.write_text(json.dumps(record))
            backup_path.unlink()
            server = Server(grace=2500, state_file=state_path, port=port).start()
            invalid = Client(port); clients.append(invalid)
            invalid.send({"type": "join", "code": aw["code"], "token": aw["token"]})
            assert invalid.until("error")["fatal"]
        finally:
            close_all(clients)
            server.stop()
            server.log.close()
    print("PASS server restart: private atomic snapshots,108-card validation, same-seat/hand/phase restoration, persisted forfeits, backup recovery, corrupt-state rejection")


if __name__ == "__main__":
    main()
