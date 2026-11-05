"""Execute real Swift lifecycle implementations with dependency doubles.

macOS: compiles real mailbox/event/cleanup code and executes a 31-second RPC.
Other Swift hosts: executes the portable real cleanup concurrency gate only.
No Swift: explicitly SKIP behavior (never report source tests as behavior).
"""
import datetime
import hashlib
import json
import os
import pathlib
import sys
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NECORE = ROOT / "ios/NECore"

def run_recorded(command, evidence, label, *, timeout):
    """Persist child evidence before raising; a crash/timeout never becomes PASS."""
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = {"command": command, "timeout_seconds": timeout, "started_utc": started}
    stdout, stderr = b"", b""
    failure = None
    try:
        child = subprocess.run(command, capture_output=True, timeout=timeout)
        stdout, stderr = child.stdout, child.stderr
        result["returncode"] = child.returncode
        child.check_returncode()
    except subprocess.TimeoutExpired as error:
        stdout, stderr = error.stdout or b"", error.stderr or b""
        result.update(returncode=None, error="TimeoutExpired")
        failure = error
    except (subprocess.CalledProcessError, OSError) as error:
        result.setdefault("returncode", None)
        result["error"] = type(error).__name__
        failure = error
    finally:
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / (label + ".stdout.txt")).write_bytes(stdout)
        (evidence / (label + ".stderr.txt")).write_bytes(stderr)
        (evidence / (label + ".result.json")).write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(stdout.decode("utf-8", errors="replace"), end="", flush=True)
        print(stderr.decode("utf-8", errors="replace"), end="", file=sys.stderr, flush=True)
    if failure is not None:
        raise failure


class SwiftLifecycleBehavior(unittest.TestCase):
    def test_actual_swift_implementations(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("swiftc unavailable; Swift behavior and native compilation NOT verified")
        with tempfile.TemporaryDirectory(prefix="ios-lifecycle-") as directory:
            directory = pathlib.Path(directory)
            main = directory / "main.swift"
            executable = directory / ("behavior.exe" if platform.system() == "Windows" else "behavior")
            sources = [NECORE / "PacketTunnelLifecycleCleanup.swift"]
            if platform.system() == "Darwin":
                main.write_text((ROOT / "scripts/fixtures/ios_lifecycle_main.swift").read_text(), encoding="utf-8")
                sources += [NECORE / "RPCSession.swift", NECORE / "NECoreEventQueue.swift", NECORE / "PacketTunnelCommandServer.swift"]
            else:
                main.write_text('''import Foundation
let lock = NSLock()
var count = 0
let cleanup = PacketTunnelLifecycleCleanup(actions: [{ lock.lock(); count += 1; lock.unlock() }])
DispatchQueue.concurrentPerform(iterations: 1000) { _ in cleanup.cleanup() }
precondition(count == 1)
print("PASS: actual concurrent cleanup; Darwin mailbox/event behavior not available")
''', encoding="utf-8")
            # Lives outside TemporaryDirectory, also beneath the existing always-upload
            # error-envelope artifact path on CI; no workflow edit is needed.
            artifact_root = pathlib.Path(os.environ.get("IOS_LIFECYCLE_EVIDENCE_DIR") or
                                         pathlib.Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / "error-envelope" / "ios-lifecycle")
            evidence = artifact_root / directory.name
            evidence.mkdir(parents=True, exist_ok=True)
            manifest = {"platform": platform.platform(), "python": sys.version,
                        "runner_os": os.environ.get("RUNNER_OS"),
                        "runner_arch": os.environ.get("RUNNER_ARCH"),
                        "sources": []}
            for source in [*sources, main, pathlib.Path(__file__)]:
                raw = source.read_bytes()
                destination = evidence / source.name
                destination.write_bytes(raw)
                manifest["sources"].append({"path": str(source), "sha256": hashlib.sha256(raw).hexdigest()})
            (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
            print("LIFECYCLE_EVIDENCE: " + str(evidence), flush=True)
            run_recorded([swift, "-swift-version", "5", *map(str, sources), str(main), "-o", str(executable)], evidence, "compile", timeout=60)
            run_recorded([str(executable)], evidence, "behavior", timeout=55)

if __name__ == "__main__":
    unittest.main(verbosity=2)
