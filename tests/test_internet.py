#!/usr/bin/env python3
"""Black-box WebSocket protocol tests; only Python's standard library is needed."""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get("GODOT_BIN", "/opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64")

class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=4)
        self.sock.settimeout(4)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode()
        request = (f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(request.encode())
        while b"\r\n\r\n" not in self.buffer:
            self.buffer += self.sock.recv(4096)
        headers, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        assert b"101 Switching Protocols" in headers, headers
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert expected.lower() in headers.lower(), headers

    def read_exact(self, count):
        while len(self.buffer) < count:
            data = self.sock.recv(65536)
            if not data:
                raise EOFError("Socket closed")
            self.buffer += data
        value, self.buffer = self.buffer[:count], self.buffer[count:]
        return value

    def send(self, value):
        data = json.dumps(value).encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        if len(data) < 126:
            header += bytes([0x80 | len(data)])
        elif len(data) <= 65535:
            header += bytes([0xFE]) + struct.pack("!H", len(data))
        else:
            header += bytes([0xFF]) + struct.pack("!Q", len(data))
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        self.sock.sendall(header + mask + payload)

    def recv(self):
        first, second = self.read_exact(2)
        opcode, length = first & 15, second & 127
        if length == 126:
            length = struct.unpack("!H", self.read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.read_exact(8))[0]
        mask = self.read_exact(4) if second & 128 else None
        data = self.read_exact(length)
        if mask:
            data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        if opcode == 8:
            raise EOFError("WebSocket close frame")
        assert opcode == 1, opcode
        return json.loads(data)

    def until(self, kind, predicate=None):
        for _ in range(30):
            value = self.recv()
            if value.get("type") == kind and (predicate is None or predicate(value)):
                return value
        raise AssertionError(f"No {kind} message")

    def close(self):
        self.sock.close()


def main():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    process = subprocess.Popen([GODOT, "--headless", "--path", str(PROJECT),
        "--script", "server/server.gd", "--", f"--port={port}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    clients = []
    output = []
    try:
        for _ in range(20):
            line = process.stdout.readline()
            output.append(line)
            if "RAMI_SERVER_READY" in line:
                break
            if process.poll() is not None:
                raise AssertionError("Server failed to start:\n" + "".join(output))
        else:
            raise AssertionError("No server readiness line")
        a = Client(port); clients.append(a)
        a.send({"type": "create", "name": "Alice"})
        welcome_a = a.until("welcome")
        room_a = welcome_a["code"]
        assert welcome_a["player"] == 0 and welcome_a["is_host"]
        assert len(welcome_a["token"]) == 48
        a.until("lobby")
        b = Client(port); clients.append(b)
        b.send({"type": "join", "name": "Benoît", "code": room_a})
        welcome_b = b.until("welcome")
        assert welcome_b["player"] == 1 and not welcome_b["is_host"]
        b.until("lobby")
        a.until("lobby", lambda m: len(m["data"]["players"]) == 2)
        c = Client(port); clients.append(c)
        c.send({"type": "create", "name": "Chloé"})
        welcome_c = c.until("welcome")
        assert welcome_c["code"] != room_a
        lobby_c = c.until("lobby")["data"]
        assert len(lobby_c["players"]) == 1
        c.send({"type": "start"})
        assert "deux" in c.until("error")["message"]
        b.send({"type": "start"})
        assert "hôte" in b.until("error")["message"]
        a.send({"type": "start"})
        state_a = a.until("state")["data"]
        state_b = b.until("state")["data"]
        assert state_a["your_index"] == 0 and state_b["your_index"] == 1
        assert len(state_a["hand"]) == len(state_b["hand"]) == 13
        assert not (set(state_a["hand"]) & set(state_b["hand"]))
        assert all("hand" not in summary for summary in state_a["players"])
        assert all("token" not in summary for summary in state_a["players"])
        assert not state_a["paused"]
        b.send({"type": "action", "action": {"type": "draw", "source": "deck"}})
        assert b.until("error")["message"]
        a.send({"type": "action", "action": {"type": "draw", "source": "deck"}})
        drawn = a.until("state")["data"]
        assert len(drawn["hand"]) == 14
        time.sleep(0.06)
        a.send({"type": "action", "action": {"type": "discard", "card": drawn["hand"][0]}})
        after = a.until("state")["data"]
        assert after["turn"] == 1 and len(after["hand"]) == 13
        b.close()
        paused = a.until("state", lambda m: m["data"]["paused"])["data"]
        assert paused["paused"]
        fake = Client(port); clients.append(fake)
        fake.send({"type": "join", "code": room_a, "token": "wrong"})
        assert fake.until("error")["fatal"]
        rejoined = Client(port); clients.append(rejoined)
        rejoined.send({"type": "join", "code": room_a, "token": welcome_b["token"]})
        restored = rejoined.until("welcome")
        assert restored["player"] == 1 and restored["token"] == welcome_b["token"]
        restored_state = rejoined.until("state")["data"]
        assert restored_state["hand"] == state_b["hand"]
        assert not restored_state["paused"]
        assert not a.until("state", lambda m: not m["data"]["paused"])["data"]["paused"]
        # A client cannot claim an occupied authenticated seat with a stolen token.
        duplicate = Client(port); clients.append(duplicate)
        duplicate.send({"type": "join", "code": room_a, "token": welcome_b["token"]})
        assert duplicate.until("error")["fatal"]
        print("PASS internet: independent rooms, host permissions, private hands, turn enforcement, pause, reconnect, occupied-seat rejection")
    finally:
        for client in clients:
            try:
                client.close()
            except OSError:
                pass
        process.terminate()
        try:
            tail = process.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            process.kill()
            tail = process.communicate()[0]
        if "SCRIPT ERROR" in tail or "Parse Error" in tail:
            raise AssertionError(tail)

if __name__ == "__main__":
    main()
