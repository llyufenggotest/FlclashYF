// Native operation-count fixture. Compiled with complete production declarations.
// No timer/clock/session/I/O/diagnostics algorithm is replaced.
import Foundation
import CoreFoundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = CommandLine.arguments[2]
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

enum PowerBoundary {
  static func containerURL(forSecurityApplicationGroupIdentifier: String) -> URL? { root }
}

enum PowerProbe {
  static let lock = NSLock()
  static var counts: [String: Int] = [:]
  static func bump(_ name: String) { lock.lock(); counts[name, default: 0] += 1; lock.unlock() }
  static func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
  static func delta(_ before: [String: Int]) -> [String: Int] {
    snapshot().reduce(into: [:]) { $0[$1.key] = $1.value - (before[$1.key] ?? 0) }
  }
}

func finish(_ failures: [String], metrics: [String: Any] = [:]) -> Never {
  let row: [String: Any] = ["fixture": "ios-power-production-v1", "mode": mode,
    "status": failures.isEmpty ? "pass" : "semantic_failure", "failures": failures,
    "metrics": metrics]
  print(String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
  exit(failures.isEmpty ? 0 : 1)
}
func check(_ okay: Bool, _ name: String) { if !okay { finish([name]) } }
func sleepMS(_ ms: UInt32) { usleep(ms * 1000) }
func waitUntil(_ seconds: Double, _ predicate: () -> Bool) -> Bool {
  let end = ProcessInfo.processInfo.systemUptime + seconds
  repeat { if predicate() { return true }; sleepMS(5) } while ProcessInfo.processInfo.systemUptime < end
  return predicate()
}
func rows() -> [[String: Any]] {
  (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.filter {
    $0.lastPathComponent.hasPrefix("ios-switch-") && $0.pathExtension == "log"
  }.flatMap { url -> [[String: Any]] in
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
  } ?? []
}
SwitchDiagnostics.setTestDirectory(root, bundleIdentifier: "audit.power.NECore")

if mode == "p02" {
  // Deliberate ingress workload, NOT a claim that the entire seven-stage RPC chain ran.
  // Stage vocabulary comes from the original production call sites.
  let stages = ["core_request_begin", "provider_request_begin", "provider_request_send",
                "rpc_received", "rpc_reply", "provider_request_reply", "core_request_reply"]
  let before = PowerProbe.snapshot()
  var expected: [String: [String: Int]] = [:]
  for tick in 0..<100 {
    for method in ["getTraffic", "getTotalTraffic"] {
      let data = Data("{\"method\":\"\(method)\",\"id\":\"\(tick)\"}".utf8)
      for event in stages {
        SwitchDiagnostics.record(event, fields: ["method": method,
          "request_id": SwitchDiagnostics.requestID(data), "status": "response", "error_type": "none"])
        expected[method, default: [:]][event, default: 0] += 1
      }
    }
  }
  // Candidate summaries must flush within a bounded 2s window, even after input stops.
  sleepMS(2200)
  let measured = PowerProbe.delta(before)
  let output = rows()
  var observed: [String: [String: Int]] = [:]
  for row in output {
    guard let method = row["method"] as? String, expected[method] != nil else { continue }
    if let event = row["event"] as? String, stages.contains(event) {
      observed[method, default: [:]][event, default: 0] += 1
    } else if row["event"] as? String == "rpc_stats_summary", let counts = row["counts"] as? [String: NSNumber] {
      for (event, number) in counts where stages.contains(event) {
        observed[method, default: [:]][event, default: 0] += number.intValue
      }
    }
  }
  check(observed == expected, "p02_stats_accounting_loss_or_duplicate")
  var failures: [String] = []
  for name in ["footprint", "json_encode", "append"] {
    if measured[name, default: 0] > 28 { failures.append("p02_" + name + "_budget") }
  }
  finish(failures, metrics: ["input_records": 1400, "operation_counts": measured,
    "accounted": observed, "scope": "real record ingress; not whole RPC chain or device power"])
}

if mode == "diagnostic-safety" {
  let id = SwitchDiagnostics.requestID(Data("detail".utf8))
  let attempt = UUID().uuidString
  let details = ["tunnel_start", "core_route_changed", "core_request_failure",
                 "provider_request_failure", "rpc_core_empty", "config_ne_apply_begin", "config_ne_apply_end"]
  for event in details {
    SwitchDiagnostics.record(event, fields: ["method": "getTraffic", "request_id": id,
      "parent_request_id": id, "attempt_id": attempt, "generation": "42", "error_type": "send_failed",
      "payload": "DO-NOT-LOG-SECRET"])
  }
  // Configuration success and nil-response statistics must not be coalesced away.
  SwitchDiagnostics.record("rpc_reply", fields: ["method": "setupConfig", "request_id": id, "status": "response"])
  SwitchDiagnostics.record("rpc_reply", fields: ["method": "getTraffic", "request_id": id, "status": "nil_response"])
  // Successful routine traffic still has full request-level attribution in the
  // lifecycle/config/switch detail window, not merely failure-path coverage.
  SwitchDiagnostics.record("provider_request_begin", fields: ["method": "getTraffic", "request_id": id,
    "status": "response", "error_type": "none"])
  let output = rows()
  check(output.count == details.count + 3, "detailed_trace_missing_or_duplicate")
  check(output.allSatisfy { $0["process_id"] as? String == SwitchDiagnostics.processID }, "detailed_process_correlation")
  for event in details {
    check(output.contains { $0["event"] as? String == event && $0["request_id"] as? String == id
      && $0["parent_request_id"] as? String == id && $0["attempt_id"] as? String == attempt
      && $0["generation"] as? String == "42" }, "detailed_correlation_" + event)
  }
  check(output.contains { $0["method"] as? String == "setupConfig" && $0["request_id"] as? String == id }, "configuration_trace_missing")
  check(output.contains { $0["status"] as? String == "nil_response" && $0["request_id"] as? String == id }, "nil_response_trace_missing")
  check(output.contains { $0["event"] as? String == "provider_request_begin" && $0["request_id"] as? String == id }, "successful_switch_window_trace_missing")
  check(!String(describing: output).contains("DO-NOT-LOG-SECRET"), "diagnostic_privacy")
  finish([])
}

// Keep the main dispatch/run loop available for real Darwin callbacks.
DispatchQueue.global().async {
let store = PacketTunnelSharedStateStore()
let req = root.appendingPathComponent("core-rpc/req", isDirectory: true)
let resp = root.appendingPathComponent("core-rpc/resp", isDirectory: true)
try! FileManager.default.createDirectory(at: req, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: resp, withIntermediateDirectories: true)
func publish(_ id: String, owner: RPCOwner, method: String = "getTraffic", deadline: Date = Date().addingTimeInterval(120)) {
  let request = RPCRequest(version: RPCWire.version, owner: owner, deadline: deadline,
    data: Data("{\"method\":\"\(method)\",\"id\":\"\(id)\"}".utf8))
  try! JSONEncoder().encode(request).write(to: req.appendingPathComponent(id + ".req"), options: .atomic)
}
func reply(_ id: String) -> RPCReply? {
  guard let data = try? Data(contentsOf: resp.appendingPathComponent(id + ".resp")) else { return nil }
  return try? JSONDecoder().decode(RPCReply.self, from: data)
}
func notify() {
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
    CFNotificationName(PacketTunnelEnvironment.commandNotificationName as CFString), nil, nil, true)
}
let success = Data(#"{"result":"","error":null}"#.utf8)
let callbackLock = NSLock()
var held: [String: [(Data?) -> Void]] = [:]
var calls: [String: Int] = [:]
let server = PacketTunnelCommandServer(sharedStateStore: store, invoke: { data, completion in
  let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  let id = object["id"] as! String
  callbackLock.lock(); calls[id, default: 0] += 1
  let hold = ["reuse", "long-config"].contains(id)
  if hold { held[id, default: []].append(completion) }
  callbackLock.unlock()
  if !hold { completion(success) }
})
func count(_ id: String) -> Int { callbackLock.lock(); defer { callbackLock.unlock() }; return calls[id, default: 0] }
func complete(_ id: String, _ index: Int) {
  callbackLock.lock(); let callback = held[id]![index]; callbackLock.unlock(); callback(success)
}
let attempt = UUID()
let owner = RPCOwner(attempt: attempt, generation: 7, nonce: UUID())

if mode == "mailbox-safety" {
  RPCSession.testFailNextPublication = true
  check(!server.start(attempt: attempt), "failed_publication_started_server")
  check(PowerProbe.snapshot()["observer_add", default: 0] == 0, "failed_start_registered_observer")
  check(PowerProbe.snapshot()["timer", default: 0] == 0, "failed_start_armed_timer")
}
if mode == "p03" {
  check(server.start(attempt: attempt), "idle_server_start")
  // Observe initial queued drain before resetting the counters.
  check(waitUntil(1) { PowerProbe.snapshot()["drain", default: 0] >= 1 }, "initial_drain_missing")
  let before = PowerProbe.snapshot()
  sleepMS(4200)
  server.stop()
  let measured = PowerProbe.delta(before)
  var failures: [String] = []
  if measured["timer", default: 0] > 6 { failures.append("p03_idle_timer_budget") }
  if measured["prune", default: 0] > 1 { failures.append("p03_idle_prune_budget") }
  if measured["enumerate", default: 0] > 9 { failures.append("p03_idle_enumeration_budget") }
  finish(failures, metrics: ["window_ms": 4200, "operation_counts": measured])
}
check(mode == "mailbox-safety", "unknown_fixture_mode")

// Cold backlog: valid same-attempt work survives; old owner and expired work do not execute.
publish("cold-valid", owner: owner)
publish("cold-old", owner: RPCOwner(attempt: UUID(), generation: 7, nonce: UUID()))
publish("cold-expired", owner: owner, deadline: Date().addingTimeInterval(-1))
publish("too-far", owner: owner, deadline: Date().addingTimeInterval(140))
let orphanReq = req.appendingPathComponent("old.req")
let orphanResp = resp.appendingPathComponent("old.resp")
try! Data("old".utf8).write(to: orphanReq); try! Data("old".utf8).write(to: orphanResp)
for file in [orphanReq, orphanResp] {
  try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-181)], ofItemAtPath: file.path)
}
check(server.start(attempt: attempt), "cold_server_start")
check(server.start(attempt: attempt), "same_attempt_start_idempotence")
check(!server.start(attempt: UUID()), "different_live_attempt_rejected")
check(waitUntil(2) { reply("cold-valid") != nil }, "cold_valid_backlog_lost")
check(reply("cold-valid")?.owner == owner, "reply_owner_nonce_generation")
check(count("cold-valid") == 1 && count("cold-old") == 0 && count("cold-expired") == 0 && count("too-far") == 0, "cold_admission_integrity")
check(!FileManager.default.fileExists(atPath: orphanResp.path), "initial_orphan_prune")

// Deliberately publish with NO Darwin notification: periodic fallback is mandatory.
publish("missed-notify", owner: owner)
check(waitUntil(1.8) { reply("missed-notify") != nil }, "missed_notification_fallback")
let notifications = PowerProbe.snapshot()["notification", default: 0]
publish("notified", owner: owner); notify()
check(waitUntil(1) { PowerProbe.snapshot()["notification", default: 0] > notifications }, "darwin_callback_not_observed")
check(waitUntil(0.5) { reply("notified") != nil }, "notification_fast_drain")

// Old callback must not write a reply or release a reused filename's current token.
publish("reuse", owner: owner); notify()
check(waitUntil(2) { count("reuse") == 1 }, "old_callback_admission")
server.stop()
let stopped = PowerProbe.snapshot()
sleepMS(500)
check(PowerProbe.snapshot()["timer"] == stopped["timer"], "stopped_timer_fires")
check(PowerProbe.snapshot()["enumerate"] == stopped["enumerate"], "stopped_directory_scan")
let nextAttempt = UUID()
let nextOwner = RPCOwner(attempt: nextAttempt, generation: 8, nonce: UUID())
check(server.start(attempt: nextAttempt), "restart_start")
publish("reuse", owner: nextOwner); notify()
check(waitUntil(2) { count("reuse") == 2 }, "reused_filename_new_admission")
complete("reuse", 0); sleepMS(100)
check(reply("reuse") == nil, "stale_callback_published")
complete("reuse", 1)
check(waitUntil(2) { reply("reuse")?.owner == nextOwner }, "new_token_lost_after_stale_callback")

// Real >30s execution with a real 120s client deadline: no accelerated production clock.
let longOwner = RPCOwner(attempt: nextAttempt, generation: 9, nonce: UUID())
publish("long-config", owner: longOwner, method: "setupConfig")
notify(); check(waitUntil(2) { count("long-config") == 1 }, "long_configuration_admission")
sleepMS(31000)
check(reply("long-config") == nil && count("long-config") == 1, "long_configuration_reexecuted")
complete("long-config", 0)
check(waitUntil(2) { reply("long-config")?.owner == longOwner }, "long_configuration_reply_lost")
let receiptData = UserDefaults(suiteName: PacketTunnelEnvironment.appGroupIdentifier)?.data(forKey: "appliedConfigurationRequest")
let receipt = receiptData.flatMap { try? JSONDecoder().decode(RPCAppliedReceipt.self, from: $0) }
check(receipt?.owner == longOwner, "long_configuration_receipt_owner")
server.stop()
check(RPCSession.readPublished(from: root) == nil, "stop_session_not_retired")
let counts = PowerProbe.snapshot()
check(counts["observer_add", default: 0] == 2 && counts["observer_remove", default: 0] == 2, "observer_lifecycle_balance")
UserDefaults.standard.removePersistentDomain(forName: PacketTunnelEnvironment.appGroupIdentifier)
finish([], metrics: ["operation_counts": counts, "long_configuration_delay_ms": 31000,
  "client_deadline_seconds": 120, "device_energy_verified": false])
}
dispatchMain()
