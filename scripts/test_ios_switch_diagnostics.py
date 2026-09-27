#!/usr/bin/env python3
"""Compile and exercise the production diagnostics logger with Apple's SDK."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ios/Shared/SwitchDiagnostics.swift"
HARNESS = r'''
import Foundation

func check(_ condition: Bool, _ message: String) {
  if !condition { fatalError(message) }
}

let mode = CommandLine.arguments[1]
if mode == "identity" {
  check(UUID(uuidString: SwitchDiagnostics.processID) != nil, "process UUID")
  check(SwitchDiagnostics.processID == SwitchDiagnostics.processID, "stable process UUID")
  check(SwitchDiagnostics.requestID(Data("abc".utf8)) == "ba7816bf8f01cfea", "SHA256 vector")
  check(SwitchDiagnostics.requestID(Data()) == "e3b0c44298fc1c14", "empty SHA256 vector")
  check(SwitchDiagnostics.requestID(Data("abd".utf8)) != SwitchDiagnostics.requestID(Data("abc".utf8)), "distinct bytes")
  print(SwitchDiagnostics.processID)
} else if mode == "metadata" {
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "com.follow.clash.llyufeng")
  let secret = "https://private.example/sub?token=secret-token"
  let request = Data("{\"method\":\"setupConfig\",\"arguments\":\"\(secret)\"}".utf8)
  check(SwitchDiagnostics.method(request) == "setupConfig", "known method")
  for input in ["{}", "[]", "null", "not json", "{\"method\":42}",
                "{\"method\":\"secret-token\"}"] {
    check(SwitchDiagnostics.method(Data(input.utf8)) == "unknown", "unknown method privacy")
  }
  SwitchDiagnostics.record("provider_request_begin", fields: [
    "method": "setupConfig", "request_id": SwitchDiagnostics.requestID(request),
    "request_bytes": String(request.count), "response_bytes": "0", "elapsed_ms": "12",
    "status": "connected", "stage": "begin", "route": "extension", "reason": "none",
    "error_type": "none", "core_phase": "apply_config_hub_apply_end", "success": "true",
    "attempt_id": SwitchDiagnostics.processID, "profile_digest": SwitchDiagnostics.requestID(request),
    "status_before": "3", "status_after": "5", "route_before": "network_extension",
    "route_after": "app", "outcome": "not_empty_success",
    "parent_request_id": SwitchDiagnostics.requestID(request),
    "payload": secret, "error": secret, "pid": secret, "process_id": secret,
  ])
  SwitchDiagnostics.record(secret, fields: [
    "method": secret, "stage": secret, "error_type": secret, "reason": secret,
    "request_id": secret, "attempt_id": secret, "profile_digest": secret,
    "elapsed_ms": "nan", "response_bytes": "-1", "request_bytes": "1e99",
    "status": secret, "route": secret, "core_phase": secret, "success": "yes",
  ])
  SwitchDiagnostics.record("secret_token", fields: [
    "stage": "secret_token", "reason": "secret_token", "error_type": "secret_token",
    "core_phase": "secret_token", "method": "secret_token", "route": "secret_token",
  ])
  let url = directory.appendingPathComponent("ios-switch-Runner.log")
  let text = try String(contentsOf: url, encoding: .utf8)
  check(!text.contains("private.example") && !text.contains("secret-token") && !text.contains("secret_token"), "no arbitrary text")
  let rows = try text.split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
  check(rows.count == 3, "synchronous writes")
  let first = rows[0]
  check(first["event"] as? String == "provider_request_begin", "event retained")
  check(first["process_id"] as? String == SwitchDiagnostics.processID, "process ID protected")
  check((first["pid"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier, "PID protected")
  check((first["uptime_ms"] as? NSNumber)?.doubleValue ?? -1 >= 0, "monotonic clock")
  check((first["footprint_mb"] as? NSNumber)?.doubleValue ?? -1 >= 0, "Darwin footprint")
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  check(formatter.date(from: first["timestamp"] as! String) != nil, "fractional ISO8601 time")
  for key in ["method", "request_id", "request_bytes", "response_bytes", "elapsed_ms", "status",
              "stage", "route", "reason", "error_type", "core_phase", "success", "attempt_id", "profile_digest",
              "status_before", "status_after", "route_before", "route_after", "outcome", "parent_request_id"] {
    check(first[key] != nil, "allowed field \(key)")
  }
  check(first["payload"] == nil && first["error"] == nil, "unknown keys dropped")
  check(rows[1]["request_bytes"] == nil && rows[1]["response_bytes"] == nil && rows[1]["elapsed_ms"] == nil, "invalid numbers dropped")
} else if mode == "bridge" {
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "com.follow.clash.llyufeng.NECore")
  let cls: AnyObject = NSClassFromString("SwitchDiagnostics")! as AnyObject
  check(cls.responds(to: NSSelectorFromString("recordCorePhase:")), "Objective-C selector exported")
  _ = cls.perform(NSSelectorFromString("recordCorePhase:"), with:
    "{\"core_phase\":\"apply_config_hub_apply_end\",\"success\":false,\"heap_alloc_bytes\":101,\"heap_sys_bytes\":202,\"num_gc\":3,\"goroutines\":4,\"elapsed_ms\":12,\"generation\":7,\"config_generation\":7,\"payload\":\"secret-token\"}")
  SwitchDiagnostics.recordCorePhase("{\"core_phase\":\"secret-token\",\"success\":\"secret-token\",\"heap_alloc_bytes\":\"secret-token\"}")
  SwitchDiagnostics.recordCorePhase("{\"core_phase\":\"apply_config_hub_apply_end\",\"success\":1,\"heap_alloc_bytes\":true,\"num_gc\":-1,\"goroutines\":1.5,\"elapsed_ms\":\"12\"}")
  for input in ["secret-token", "[]", "null", String(repeating: "x", count: 10000)] {
    SwitchDiagnostics.recordCorePhase(input)
  }
  let text = try String(contentsOf: directory.appendingPathComponent("ios-switch-NECore.log"), encoding: .utf8)
  check(!text.contains("secret-token"), "bridge privacy")
  let rows = try text.split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
  check(rows.count == 2, "reject malformed and unknown core phase messages")
  let first = rows[0]
  check(first["event"] as? String == "core_phase", "bridge event")
  check(first["success"] as? String == "false", "bridge boolean")
  for (key, value) in ["heap_alloc_bytes": "101", "heap_sys_bytes": "202", "num_gc": "3",
                       "goroutines": "4", "elapsed_ms": "12", "generation": "7", "config_generation": "7"] {
    check(first[key] as? String == value, "bridge numeric field \(key)")
  }
  for key in ["success", "heap_alloc_bytes", "num_gc", "goroutines", "elapsed_ms"] {
    check(rows[1][key] == nil, "bridge rejects wrong type \(key)")
  }
} else if mode == "paths" {
  let host = "com.follow.clash.llyufeng"
  check(SwitchDiagnostics.appGroupIdentifier(bundleIdentifier: host) == "group.\(host)", "Runner group")
  check(SwitchDiagnostics.appGroupIdentifier(bundleIdentifier: host + ".NECore") == "group.\(host)", "NE group")
  check(SwitchDiagnostics.appGroupIdentifier(bundleIdentifier: host + ".NECore.extra") == "group.\(host).NECore.extra", "strip suffix only")
  check(SwitchDiagnostics.appGroupIdentifier(bundleIdentifier: "") == nil, "no guessed group")
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  for bundle in [host, host + ".NECore"] {
    SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: bundle)
    SwitchDiagnostics.record("tunnel_start")
  }
  check(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) ==
        Set(["ios-switch-Runner.log", "ios-switch-NECore.log"]), "separate process logs")
} else if mode == "concurrency" {
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "com.follow.clash.llyufeng")
  DispatchQueue.concurrentPerform(iterations: 1000) { index in
    SwitchDiagnostics.record("provider_request_begin", fields: ["request_bytes": String(index)])
  }
  let text = try String(contentsOf: directory.appendingPathComponent("ios-switch-Runner.log"), encoding: .utf8)
  let rows = try text.split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
  check(rows.count == 1000, "no concurrent records lost")
  check(Set(rows.compactMap { $0["request_bytes"] as? String }).count == 1000, "no interleaved/duplicate records")
  let uptimes = rows.map { ($0["uptime_ms"] as! NSNumber).doubleValue }
  check(uptimes == uptimes.sorted(), "timestamps sampled inside serialized writes")
} else if mode == "rotation" {
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "com.follow.clash.llyufeng")
  let url = directory.appendingPathComponent("ios-switch-Runner.log")
  SwitchDiagnostics.record("tunnel_start")
  let seed = try Data(contentsOf: url)
  let cap = 2 * 1024 * 1024
  var data = Data()
  while data.count <= cap * 3 { data.append(seed) }
  try data.write(to: url)
  for index in 0..<14000 {
    SwitchDiagnostics.record("provider_request_reply", fields: ["response_bytes": String(index)])
    if index % 100 == 0 {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
      check(size <= cap, "hard cap after oversized preexisting file and repeated rotation")
    }
  }
  let text = try String(contentsOf: url, encoding: .utf8)
  let rows = try text.split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
  check(rows.last?["response_bytes"] as? String == "13999", "newest record retained")
  check(rows.count > 1, "rotation retains history")
  check(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1, "no unbounded backups")
  try Data(repeating: 120, count: cap * 3).write(to: url)
  SwitchDiagnostics.record("tunnel_start")
  let recovered = try String(contentsOf: url, encoding: .utf8)
  check(recovered.split(separator: "\n").count == 1, "discard oversized partial line")
  _ = try JSONSerialization.jsonObject(with: Data(recovered.utf8))
} else if mode == "io-failure" {
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  let blocked = directory.appendingPathComponent("not-a-directory")
  try Data().write(to: blocked)
  SwitchDiagnostics.setTestDirectory(blocked, bundleIdentifier: "com.follow.clash.llyufeng")
  SwitchDiagnostics.record("tunnel_start")
  SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "com.follow.clash.llyufeng")
  SwitchDiagnostics.record("tunnel_start")
  check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ios-switch-Runner.log").path), "logging recovers after I/O failure")
} else {
  fatalError("unknown test mode")
}
'''


def main():
    if not SOURCE.is_file():
        raise SystemExit(f"Missing production logger: {SOURCE}")
    if sys.platform != "darwin" or not shutil.which("xcrun"):
        raise SystemExit("Native diagnostics tests require macOS and xcrun (not run)")
    with tempfile.TemporaryDirectory(prefix="flclash-switch-diagnostics-") as directory:
        directory = pathlib.Path(directory)
        harness = directory / "main.swift"
        harness.write_text(HARNESS, encoding="utf-8")
        binary = directory / "diagnostics-tests"
        common = [
            "xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5", "-O",
            "-warnings-as-errors",
        ]
        subprocess.run([
            *common, "-typecheck", str(SOURCE),
        ], check=True, timeout=120)
        subprocess.run([
            *common, "-D", "SWITCH_DIAGNOSTICS_TESTING",
            str(SOURCE), str(harness), "-o", str(binary),
        ], check=True, timeout=120)
        identities = []
        for _ in range(2):
            result = subprocess.run(
                [str(binary), "identity"], check=True, capture_output=True,
                text=True, timeout=30,
            )
            identities.append(result.stdout.strip())
        if identities[0] == identities[1]:
            raise SystemExit("Process UUID must change in a new process")
        print("PASS identity: digest vectors, stable UUID, distinct process UUIDs")
        failures = []
        for mode in ["metadata", "bridge", "paths", "concurrency", "rotation", "io-failure"]:
            case_directory = directory / mode
            case_directory.mkdir()
            result = subprocess.run(
                [str(binary), mode, str(case_directory)], capture_output=True,
                text=True, timeout=90,
            )
            if result.returncode:
                failures.append(mode)
                print(f"FAIL {mode}: exit={result.returncode}\n{result.stderr[:6000]}")
            else:
                print(f"PASS {mode}")
        if failures:
            raise SystemExit(f"Native switch diagnostics failures: {failures}")
        print("All native switch diagnostics cases passed")


if __name__ == "__main__":
    main()
