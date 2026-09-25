#!/usr/bin/env python3
"""Inspect the trusted sideload dylib before Xcode packaging.

This is intentionally a strict allow-list gate: the binary is opaque third-party
code, so a same-name replacement must not silently ship.
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

EXPECTED_SHA256 = "cd903ea15657cbd356398adcb60c8872c41c29b69acc1a5dfb78a49d6e75dea5"
EXPECTED_SIZE = 70368
EXPECTED_MAGIC = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_DYLIB = 0x6

REQUIRED_MARKERS = (
    b"com.apple.security.application-groups",
    b"groupContainerURLs",
    b"containerURLForSecurityApplicationGroupIdentifier:",
    b"hooking NSUserDefaults init",
    b"SecItemAdd",
    b"SecItemCopyMatching",
    b"SecItemUpdate",
    b"SecItemDelete",
)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


path = Path(sys.argv[1] if len(sys.argv) > 1 else "ios/SideloadSupport/Tg_@HelloWorld_1024.dylib")
if not path.is_file():
    fail(f"missing dylib: {path}")
data = path.read_bytes()
if len(data) != EXPECTED_SIZE:
    fail(f"unexpected size: {len(data)}")
actual_hash = hashlib.sha256(data).hexdigest()
if actual_hash != EXPECTED_SHA256:
    fail(f"unexpected SHA-256: {actual_hash}")
if len(data) < 32:
    fail("truncated Mach-O header")
magic, cpu_type, _cpu_subtype, file_type = struct.unpack_from("<IiiI", data, 0)
if magic != EXPECTED_MAGIC:
    fail(f"not little-endian 64-bit Mach-O: 0x{magic:08x}")
if cpu_type != CPU_TYPE_ARM64:
    fail(f"not arm64: cpu_type=0x{cpu_type:08x}")
if file_type != MH_DYLIB:
    fail(f"not MH_DYLIB: file_type={file_type}")
for marker in REQUIRED_MARKERS:
    if marker not in data:
        fail(f"missing behavior marker: {marker.decode('ascii')}")
print(f"IOS_SIDELOAD_DYLIB_BINARY_PASS sha256={actual_hash} bytes={len(data)} arch=arm64")
