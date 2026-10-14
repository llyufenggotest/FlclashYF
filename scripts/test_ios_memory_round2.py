"""Round 2 real Swift tests; missing macOS/Swift is NOT a behavioral pass.
Run on macOS: python3 scripts/test_ios_memory_round2.py --require-swift
Source RED (immutable parent): --source-ref 7edcfb747a4a33d58bdbfa607c63b89c8f611821 --source-only
Source gates are integration evidence, never Swift behavior/TDD GREEN.
"""
import argparse
import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = "7edcfb747a4a33d58bdbfa607c63b89c8f611821"
SOURCES = ["NativeResourceHeartbeat.swift", "NativeDiagnosticLog.swift", "NECoreEventQueue.swift"]

def source_gate(ref=None):
    def read(name):
        path = f"ios/NECore/{name}"
        if ref:
            return subprocess.check_output(["git", "show", f"{ref}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text(encoding="utf-8")
    failures = []
    heartbeat = read(SOURCES[0])
    diagnostics = read(SOURCES[1])
    events = read(SOURCES[2])
    checks = [
        ("heartbeat owner rejects stale tick", "generation == owner" in heartbeat),
        ("heartbeat stop drains admitted worker", "worker.sync" in heartbeat),
        ("diagnostic admission bounded before dispatch", "pendingJobs" in diagnostics and "pendingBytes" in diagnostics),
        ("diagnostic rotation avoids whole-file read", "Data(contentsOf: url)" not in diagnostics),
        ("events avoid retained async payload closures", "self.queue.async {" not in events),
        ("events preserve critical overflow", "isDiscardable" in events and "coreActive = false" not in events),
    ]
    for name, ok in checks:
        print(("PASS" if ok else "FAIL") + " SOURCE ONLY: " + name)
        if not ok:
            failures.append(name)
    return not failures

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-ref")
    parser.add_argument("--source-only", action="store_true")
    parser.add_argument("--require-swift", action="store_true")
    parser.add_argument("--baseline-native", action="store_true")
    parser.add_argument("--rpc-blocker", action="store_true")
    args = parser.parse_args()
    if not (args.baseline_native or args.rpc_blocker) and not source_gate(args.source_ref):
        raise SystemExit(1)
    if args.source_only:
        return
    swift = shutil.which("swiftc")
    if platform.system() != "Darwin" or not swift:
        print("NOT EXECUTED: macOS swiftc unavailable; Swift behavior/compile NOT verified")
        if args.require_swift:
            raise SystemExit(2)
        return
    with tempfile.TemporaryDirectory(prefix="ios-memory-round2-") as temp:
        directory = pathlib.Path(temp)
        main_file = directory / "main.swift"
        binary = directory / "behavior"
        if args.baseline_native or args.rpc_blocker:
            main_file.write_text((ROOT / "scripts/fixtures/ios_memory_round2_baseline.swift").read_text(), encoding="utf-8")
            probe_sources = []
            for name in ["NECoreEventQueue.swift", "PacketTunnelCommandServer.swift"]:
                target = directory / name
                if args.baseline_native:
                    target.write_bytes(subprocess.check_output(["git", "show", f"{BASE}:ios/NECore/{name}"], cwd=ROOT))
                else:
                    target.write_bytes((ROOT / "ios/NECore" / name).read_bytes())
                probe_sources.append(str(target))
            subprocess.run([swift, "-swift-version", "5", *probe_sources, str(main_file), "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary), "rpc" if args.rpc_blocker else "event"], capture_output=True, text=True, timeout=15)
            print(result.stdout, end="")
            expected = "EXPECTED_BLOCKER_RED" if args.rpc_blocker else "EXPECTED_BASELINE_RED"
            if result.returncode != 1 or expected not in result.stdout:
                raise SystemExit(f"Native RED not established: exit={result.returncode} {result.stderr}")
            print("Confirmed real native expected RED (not a production acceptance pass)")
            return
        main_file.write_text((ROOT / "scripts/fixtures/ios_memory_round2_main.swift").read_text(), encoding="utf-8")
        command = [swift, "-swift-version", "5", "-D", "IOS_MEMORY_TESTING", *[str(ROOT / "ios/NECore" / n) for n in SOURCES], str(main_file), "-o", str(binary)]
        print("COMPILE:", " ".join(command), flush=True)
        subprocess.run(command, check=True, timeout=90)
        subprocess.run([str(binary)], check=True, timeout=40)

if __name__ == "__main__":
    main()
