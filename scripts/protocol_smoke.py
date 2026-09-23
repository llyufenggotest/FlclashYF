#!/usr/bin/env python3
"""Source/configuration smoke gates for the pinned protocol core."""

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MIHOMO = ROOT / "core" / "mihomo"

CONTRACTS = {
    "oppa": ("oppa", ["transport/oppa", "adapter"]),
    "shanlian-anytls": ("#sl", ["transport/anytls"]),
    "oix-snell": ("#oix", ["transport/snell", "adapter/outbound"]),
    "fastup": ("fastup", ["adapter", "adapter/outbound"]),
    "x365": ("x365", ["adapter", "adapter/outbound"]),
    "juzi": ("juzi", ["transport/vless", "adapter/outbound"]),
    "pure": ("pure", ["transport/vless", "adapter/outbound"]),
    "blackstone-xhttp": ("blackstone", ["transport", "adapter"]),
    "viewturbo": ("sing-shadowsocks2", ["go.mod"]),
}


def tracked_files():
    output = subprocess.check_output(
        ["git", "-C", str(MIHOMO), "ls-files", "*.go", "go.mod"], text=True
    )
    return [MIHOMO / line for line in output.splitlines() if line]


def main():
    files = tracked_files()
    contents = {}
    for path in files:
        try:
            contents[path] = path.read_text(encoding="utf-8", errors="ignore").lower()
        except OSError:
            pass

    missing = []
    for name, (needle, areas) in CONTRACTS.items():
        matches = [
            path
            for path, content in contents.items()
            if needle in content and any(area in path.as_posix() for area in areas)
        ]
        if not matches:
            missing.append(name)
        else:
            print(f"{name}: {len(matches)} implementation/test files")

    module = (ROOT / ".gitmodules").read_text(encoding="utf-8")
    if "core/sing-shadowsocks2" not in module:
        missing.append("viewturbo-submodule")

    if missing:
        print("missing protocol contracts: " + ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
