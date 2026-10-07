"""Execute real Swift lifecycle implementations with dependency doubles.

macOS: compiles real mailbox/event/cleanup code and executes a 31-second RPC.
Other Swift hosts: executes the portable real cleanup concurrency gate only.
No Swift: explicitly SKIP behavior (never report source tests as behavior).
"""
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NECORE = ROOT / "ios/NECore"

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
                sources += [NECORE / "NECoreEventQueue.swift", NECORE / "PacketTunnelCommandServer.swift"]
            else:
                main.write_text('''import Foundation
let lock = NSLock()
var count = 0
let cleanup = PacketTunnelLifecycleCleanup(actions: [{ lock.lock(); count += 1; lock.unlock() }])
DispatchQueue.concurrentPerform(iterations: 1000) { _ in cleanup.cleanup() }
precondition(count == 1)
print("PASS: actual concurrent cleanup; Darwin mailbox/event behavior not available")
''', encoding="utf-8")
            subprocess.run([swift, "-swift-version", "5", *map(str, sources), str(main), "-o", str(executable)], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=55)

if __name__ == "__main__":
    unittest.main(verbosity=2)
