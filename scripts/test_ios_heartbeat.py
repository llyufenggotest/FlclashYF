#!/usr/bin/env python3
"""Compile and execute the production heartbeat on macOS, without a VPN."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation

final class NECoreBridge {
  static func releaseMemory() {}
}

final class NativeDiagnosticLog {
  static let shared = NativeDiagnosticLog()
  private let lock = NSLock()
  private var lines: [String] = []
  func append(_ message: String) {
    lock.lock()
    lines.append(message)
    lock.unlock()
  }
  var heartbeatCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return lines.filter { $0.hasPrefix("heartbeat ") }.count
  }
}

func check(_ condition: Bool, _ message: String) {
  if !condition { fatalError(message) }
}

let mode = CommandLine.arguments[1]
if mode == "first-sample" {
  let footprint = Int(CommandLine.arguments[2])!
  check(NativeResourceHeartbeat.shouldLogHeartbeat(
    uptimeSeconds: 0, footprintMB: footprint,
    lastLoggedUptime: -.greatestFiniteMagnitude,
    lastLoggedFootprintMB: Int.min
  ), "first sample must be logged")
} else if mode == "policy" {
  for (now, footprint, previous, expected) in [
    (1.0, 20, 20, false), (10.0, 20, 20, true),
    (1.0, 23, 20, true), (1.0, 17, 20, true),
    (1.0, 22, 20, false), (1.0, 44, 44, true)
  ] {
    check(NativeResourceHeartbeat.shouldLogHeartbeat(
      uptimeSeconds: now, footprintMB: footprint,
      lastLoggedUptime: 0, lastLoggedFootprintMB: previous
    ) == expected, "throttle policy changed")
  }
  let base = NativeResourceHeartbeat.baseReclaimPolicy
  check(NativeResourceHeartbeat.nextReclaimPolicy(current: base, yieldMB: 2) == base,
        "effective reclamation must preserve base policy")
} else if mode == "timer" {
  let heartbeat = NativeResourceHeartbeat(reclaim: {})
  heartbeat.start()
  Thread.sleep(forTimeInterval: 0.2)
  check(NativeDiagnosticLog.shared.heartbeatCount >= 1, "missing initial heartbeat")
  heartbeat.stop()
  Thread.sleep(forTimeInterval: 0.1)
  let beforeRestart = NativeDiagnosticLog.shared.heartbeatCount
  heartbeat.start()
  Thread.sleep(forTimeInterval: 0.2)
  heartbeat.stop()
  check(NativeDiagnosticLog.shared.heartbeatCount > beforeRestart,
        "restart must emit a new first sample")
} else {
  fatalError("unknown test mode")
}
print("PASS \(CommandLine.arguments.dropFirst().joined(separator: " "))")
'''


def main():
    with tempfile.TemporaryDirectory(prefix="flclash-heartbeat-") as directory:
        directory = pathlib.Path(directory)
        harness = directory / "main.swift"
        harness.write_text(HARNESS)
        binary = directory / "heartbeat-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-O",
            str(ROOT / "ios/NECore/NativeResourceHeartbeat.swift"),
            str(harness), "-o", str(binary),
        ], check=True)
        failures = []
        cases = [["first-sample", str(value)] for value in [-1, 0, 6, 7, 30, 43, 44]]
        cases += [["policy"], ["timer"]]
        for case in cases:
            result = subprocess.run([str(binary), *case], capture_output=True, text=True, timeout=15)
            print(result.stdout, end="", flush=True)
            if result.returncode:
                failures.append(case)
                print(f"FAIL {case}: exit={result.returncode}\n{result.stderr[:4000]}", flush=True)
        if failures:
            raise SystemExit(f"Heartbeat regressions: {failures}")
        print(f"All {len(cases)} native heartbeat cases passed")


if __name__ == "__main__":
    main()
