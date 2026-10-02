#!/usr/bin/env python3
"""Simulate the app<->extension file RPC handshake used to replace the dead
`sendProviderMessage` control channel.

The Swift implementation lives in `ios/Runner/Tunnel/TunnelController.swift`
(`ProviderMessageBridge`, app side) and `ios/NECore/PacketTunnelCommandServer.swift`
(extension side). This test re-implements the exact file protocol in Python to
prove the design: atomic staging, consume-once requests, response round-trip,
timeout on an absent server, and orphan pruning. It is a design check, not a
substitute for the on-device/CI Swift build.
"""
from pathlib import Path
import os
import tempfile
import time
import unittest
import uuid

REQUEST_EXT = "req"
RESPONSE_EXT = "resp"


class Bridge:
    """App side: write a request, poll for the response."""

    def __init__(self, root: Path):
        self.req_dir = root / "core-rpc" / "req"
        self.resp_dir = root / "core-rpc" / "resp"

    def _atomic_write(self, directory: Path, name: str, data: bytes) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        tmp = directory / f".{name}.tmp"
        dst = directory / name
        tmp.write_bytes(data)
        os.replace(tmp, dst)

    def send(self, payload: bytes, server, timeout: float, poll: float = 0.02):
        request_id = uuid.uuid4().hex
        self._atomic_write(self.req_dir, f"{request_id}.{REQUEST_EXT}", payload)
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                # The server drains on its own cadence; emulate that here.
                server.drain()
                resp = self.resp_dir / f"{request_id}.{RESPONSE_EXT}"
                if resp.exists():
                    return resp.read_bytes()
                time.sleep(poll)
            raise TimeoutError("network_extension_timeout")
        finally:
            (self.req_dir / f"{request_id}.{REQUEST_EXT}").unlink(missing_ok=True)
            (self.resp_dir / f"{request_id}.{RESPONSE_EXT}").unlink(missing_ok=True)


class Server:
    """Extension side: consume requests, invoke the core, write responses."""

    def __init__(self, root: Path, invoke):
        self.req_dir = root / "core-rpc" / "req"
        self.resp_dir = root / "core-rpc" / "resp"
        self.invoke = invoke
        self.in_flight = set()
        self.processed = []

    def _atomic_write(self, directory: Path, name: str, data: bytes) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        tmp = directory / f".{name}.tmp"
        dst = directory / name
        tmp.write_bytes(data)
        os.replace(tmp, dst)

    def drain(self):
        if not self.req_dir.exists():
            return
        for req in sorted(self.req_dir.glob(f"*.{REQUEST_EXT}")):
            request_id = req.stem
            if request_id in self.in_flight:
                continue
            self.in_flight.add(request_id)
            data = req.read_bytes()
            req.unlink(missing_ok=True)  # consume before answering
            self.processed.append(request_id)
            response = self.invoke(data)
            if response is None:
                response = b'{"result":null,"error":{"code":"empty_response"}}'
            self._atomic_write(
                self.resp_dir, f"{request_id}.{RESPONSE_EXT}", response
            )
            self.in_flight.discard(request_id)


class CommandBridgeProtocol(unittest.TestCase):
    def test_round_trip_returns_core_response(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = Server(root, invoke=lambda data: b'{"result":"[nodes]"}')
            bridge = Bridge(root)
            out = bridge.send(b'{"method":"getProxies"}', server, timeout=2.0)
            self.assertEqual(out, b'{"result":"[nodes]"}')

    def test_each_request_is_processed_exactly_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = Server(root, invoke=lambda data: b'{"result":""}')
            bridge = Bridge(root)
            for _ in range(5):
                bridge.send(b'{"method":"updateConfig"}', server, timeout=2.0)
            self.assertEqual(len(server.processed), 5)
            self.assertEqual(len(set(server.processed)), 5)

    def test_nil_core_response_becomes_error_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = Server(root, invoke=lambda data: None)
            bridge = Bridge(root)
            out = bridge.send(b'{"method":"getProxies"}', server, timeout=2.0)
            self.assertIn(b"empty_response", out)

    def test_absent_server_times_out(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dead = Server(root, invoke=lambda data: b"x")
            dead.drain = lambda: None  # extension not running
            bridge = Bridge(root)
            with self.assertRaises(TimeoutError):
                bridge.send(b'{"method":"getTraffic"}', dead, timeout=0.3)

    def test_timed_out_request_leaves_no_residue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dead = Server(root, invoke=lambda data: b"x")
            dead.drain = lambda: None
            bridge = Bridge(root)
            with self.assertRaises(TimeoutError):
                bridge.send(b'{"method":"getTraffic"}', dead, timeout=0.2)
            leftover = list((root / "core-rpc" / "req").glob("*.req"))
            self.assertEqual(leftover, [])


if __name__ == "__main__":
    unittest.main()
