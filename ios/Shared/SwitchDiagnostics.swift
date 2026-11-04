import CoreFoundation
import CryptoKit
import Darwin
import MachO
import Foundation
import NetworkExtension // Apple NSError domain constants
#if canImport(UIKit)
import UIKit
#endif

@objc(SwitchDiagnostics)
final class SwitchDiagnostics: NSObject {
  static let processID = UUID().uuidString
  private static let queue = DispatchQueue(label: "com.follow.clash.switch-diagnostics")
  private static let maxBytes = 2 * 1024 * 1024
  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let methods: Set<String> = [
    "message", "initClash", "getIsInit", "forceGc", "shutdown", "releaseConfig", "validateConfig",
    "updateConfig", "getProfileConfig", "getProxies", "changeProxy", "getTraffic",
    "getTotalTraffic", "resetTraffic", "asyncTestDelay", "getConnections", "getConnectionsCount", "closeConnections",
    "resetConnections", "closeConnection", "getExternalProviders", "getExternalProvider",
    "getOverlayNetworkStatus", "activateOverlayNetwork", "pingTailscaleNode", "logoutTailscale",
    "updateGeoData", "updateExternalProvider", "sideLoadExternalProvider", "startLogNotify",
    "stopLogNotify", "startRequestNotify", "stopRequestNotify", "startListener", "stopListener",
    "getMemory", "getGoroutineCount", "crash", "setupConfig", "clearEffect", "deleteManagedPath",
    "updateDns", "generateAgeKeyPair", "convertAgeSecretKeyToPublicKey", "decryptAgeConfig",
    "convertUriSubscription",
  ]
  private static let events: Set<String> = [
    "tunnel_start", "tunnel_start_complete", "tunnel_stop", "tunnel_sleep", "tunnel_wake",
    "tunnel_status", "os_memory_pressure", "app_background", "app_foreground", "rpc_received", "rpc_reply",
    "rpc_missing_completion", "rpc_core_empty", "config_snapshot", "core_phase", "core_route_changed",
    "core_route_fallback", "core_request_begin", "core_request_reply", "core_request_failure",
    "provider_request_begin", "provider_request_send", "provider_request_reply",
    "provider_request_failure", "core_active_check_failure", "config_ne_apply_skipped",
    "config_app_apply_begin", "config_app_apply_end", "config_ne_apply_begin", "config_ne_apply_end",
    "configuration_apply_state", "tunnel_start_requested", "tunnel_stop_requested", "tunnel_reconfigure_begin",
    "tunnel_reconfigure_end", "tunnel_reconfigure_failure", "runner_launch", "runner_termination",
    "app_memory_warning", "tunnel_start_disconnect_error",
  ]
  private static let phases: Set<String> = [
    "apply_config_begin", "apply_config_lock_acquired", "apply_config_parse_begin",
    "apply_config_parse_end", "apply_config_hub_apply_begin", "apply_config_hub_apply_end",
    "apply_config_selection_begin", "apply_config_selection_end", "apply_config_listeners_begin",
    "apply_config_listeners_end", "apply_config_reclaim_begin", "apply_config_reclaim_end",
    "apply_config_complete",
  ]
  private static let numericFields: Set<String> = [
    "request_bytes", "response_bytes", "elapsed_ms", "heap_alloc_bytes", "heap_sys_bytes",
    "num_gc", "goroutines", "generation", "config_generation",
  ]
  private static let values: [String: Set<String>] = [
    "status": ["unknown", "unavailable", "invalid", "disconnected", "connecting", "connected",
               "reasserting", "disconnecting", "nil_response", "response", "0", "1", "2", "3", "4", "5", "6", "7"],
    "stage": ["begin", "end", "complete", "load", "save", "reload", "start", "stop",
              "load_manager", "save_preferences", "reload_preferences", "start_tunnel", "stop_tunnel"],
    "route": ["app", "extension", "network_extension", "unknown"],
    "reason": ["none", "unknown", "network_extension_inactive", "route_changed", "app_result_not_empty_success"],
    "error_type": ["none", "unknown", "manager_load_failed", "network_extension_unavailable",
                   "nil_response", "empty_response", "invalid_utf8", "send_failed",
                   "network_extension_request_failed", "configuration_result_failed",
                   "configuration_request_failed", "network_extension_error", "invalid_method_call",
                   "core_error_response", "unclassified_response", "delay_positive", "delay_negative",
                   "delay_missing", "delay_invalid", "disconnect_error"],
    "error_domain": ["none", "unknown", "NEVPNConnectionErrorDomain", "NEVPNErrorDomain",
                     "NSPOSIXErrorDomain", "NSURLErrorDomain", "NSCocoaErrorDomain"],
    "outcome": ["pending", "success", "not_empty_success", "failure"],
    "success": ["true", "false"],
  ]

  static func requestID(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  static func method(_ data: Data) -> String {
    struct Envelope: Decodable { let method: String }
    guard let name = try? JSONDecoder().decode(Envelope.self, from: data).method,
      methods.contains(name)
    else { return "unknown" }
    return name
  }

  // Diagnostic-only, bounded at ingress; never changes reply bytes or policy.
  static func responseErrorType(_ data: Data?, method: String) -> String {
    guard ["getTraffic", "getTotalTraffic", "asyncTestDelay"].contains(method) else { return "none" }
    let isDelay = method == "asyncTestDelay"
    guard let data else { return isDelay ? "delay_missing" : "nil_response" }
    guard data.count <= 4096 else { return isDelay ? "delay_invalid" : "unclassified_response" }
    struct Envelope: Decodable {
      let hasError: Bool
      let hasResult: Bool
      let delayClass: String
      enum CodingKeys: String, CodingKey { case error, result }
      enum DelayKeys: String, CodingKey { case value }
      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Go MethodResponse uses error,omitempty for successful replies.
        hasError = container.contains(.error) ? !(try container.decodeNil(forKey: .error)) : false
        hasResult = container.contains(.result)
        let resultMissing = !hasResult ? true : (try container.decodeNil(forKey: .result))
        if hasError {
          delayClass = "core_error_response"
        } else if resultMissing {
          delayClass = "delay_missing"
        } else if let result = try? container.nestedContainer(keyedBy: DelayKeys.self, forKey: .result) {
          let valueMissing = !result.contains(.value) ? true : (try result.decodeNil(forKey: .value))
          if valueMissing {
            delayClass = "delay_missing"
          } else if let value = try? result.decode(Int32.self, forKey: .value) {
            delayClass = value > 0 ? "delay_positive" : (value < 0 ? "delay_negative" : "delay_invalid")
          } else {
            delayClass = "delay_invalid"
          }
        } else {
          delayClass = "delay_invalid"
        }
      }
    }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
      return isDelay ? "delay_invalid" : "unclassified_response"
    }
    if envelope.hasError { return "core_error_response" }
    if isDelay { return envelope.delayClass }
    return envelope.hasResult ? "none" : "unclassified_response"
  }

  static func responseErrorType(_ response: String, method: String) -> String {
    guard ["getTraffic", "getTotalTraffic", "asyncTestDelay"].contains(method) else { return "none" }
    // Stop before allocating a Data copy of an unbounded response.
    guard response.utf8.prefix(4097).count <= 4096 else {
      return method == "asyncTestDelay" ? "delay_invalid" : "unclassified_response"
    }
    return responseErrorType(Data(response.utf8), method: method)
  }

  static func disconnectErrorFields(_ source: Error?) -> [String: String] {
    guard let error = source as NSError? else {
      return iPadErrorFields(nil).merging(["error_type": "none"]) { _, new in new }
    }
    // Exact closed-set match, not a prefix or a free-form fallback.
    let domain = values["error_domain"]!.contains(error.domain)
      && error.domain != "none" ? error.domain : "unknown"
    var result = iPadErrorFields(source)
    result["error_type"] = "disconnect_error"
    result["error_domain"] = domain
    result["error_code"] = String(error.code)
    return result
  }

  // Only successful routine traffic telemetry is aggregated. Detailed traces
  // remain synchronous during lifecycle/config/route windows and for errors.
  private static let routineEvents: Set<String> = [
    "core_request_begin", "core_request_reply", "provider_request_begin",
    "provider_request_send", "provider_request_reply", "rpc_received", "rpc_reply",
  ]
  private struct Summary {
    var fields: [String: String]
    var counts: [String: Int]
  }
  private static var summaries: [String: Summary] = [:]
  private static var summaryScheduled = false
  private static var detailedUntil: TimeInterval = 0

  static func record(_ event: String, fields: [String: String] = [:]) {
    if event.hasPrefix("ipad_") {
      if event == "ipad_provider_entry" { recordIPadCapabilities() }
      recordIPad(String(event.dropFirst(5)), fields: fields); return
    }
    if event == "tunnel_start_disconnect_error" { recordIPad("disconnect", fields: fields) }
    queue.sync {
      let now = ProcessInfo.processInfo.systemUptime
      if event.hasPrefix("tunnel_") || event.hasPrefix("config") || event == "core_phase"
        || event == "core_route_changed" || event == "core_route_fallback" {
        detailedUntil = now + 10
      }
      let routine = routineEvents.contains(event)
        && ["getTraffic", "getTotalTraffic"].contains(fields["method"] ?? "")
        && (fields["error_type"] == nil || fields["error_type"] == "none")
        && (fields["status"] == nil || fields["status"] == "response")
        && (fields["outcome"] == nil || fields["outcome"] == "success" || fields["outcome"] == "pending")
        && now >= detailedUntil
      if routine {
        // No untrusted strings or request IDs enter keys; cardinality is capped.
        let keys = ["method", "route", "route_before", "route_after", "attempt_id",
                    "generation", "config_generation"]
        var attribution: [String: String] = [:]
        for key in keys {
          if let value = fields[key], let safe = safeValue(value, for: key) {
            attribution[key] = safe
          }
        }
        let key = keys.map { attribution[$0] ?? "" }.joined(separator: "|")
        if summaries[key] == nil && summaries.count >= 16 { flushSummaries() }
        var summary = summaries[key] ?? Summary(fields: attribution, counts: [:])
        summary.counts[event, default: 0] += 1
        summaries[key] = summary
        if !summaryScheduled {
          summaryScheduled = true
          queue.asyncAfter(deadline: .now() + 1) {
            summaryScheduled = false
            flushSummaries()
          }
        }
        return
      }
      flushSummaries()
      write(event, fields: fields)
    }
  }

  private static func flushSummaries() {
    let pending = summaries
    summaries.removeAll(keepingCapacity: true)
    for summary in pending.values {
      write("rpc_stats_summary", fields: summary.fields, counts: summary.counts)
    }
  }

  // Serial queue ownership is shared by detailed and aggregate writes.
  private static func write(_ event: String, fields: [String: String], counts: [String: Int]? = nil) {
    do {
      guard let url = fileURL() else { return }
      var entry: [String: Any] = [
        "timestamp": formatter.string(from: Date()),
        "uptime_ms": ProcessInfo.processInfo.systemUptime * 1000,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "process_id": processID,
        "footprint_mb": footprintMB(),
        "event": events.contains(event) || event == "rpc_stats_summary" ? event : "unknown",
      ]
      for (key, value) in fields {
        if let safe = safeValue(value, for: key) { entry[key] = safe }
      }
      if let counts { entry["counts"] = counts }
      guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
        data.count < maxBytes
      else { return }
      data.append(0x0A)
      do {
        try append(data, to: url)
      } catch {
        // A diagnostics failure must not change tunnel or RPC behavior.
      }
    }
  }

  static func recordRunnerLaunch() {
    recordIPad("runner_launch")
    recordIPadCapabilities()
    record("runner_launch")
  }

  static func recordRunnerTermination() {
    record("runner_termination")
  }

  @objc(recordCorePhase:)
  static func recordCorePhase(_ message: String) {
    guard message.utf8.count <= 4096,
      let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
      let phase = object["core_phase"] as? String, phases.contains(phase)
    else { return }
    var fields = ["core_phase": phase]
    if let number = object["success"] as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID() {
      fields["success"] = number.boolValue ? "true" : "false"
    }
    for key in ["heap_alloc_bytes", "heap_sys_bytes", "num_gc", "goroutines",
                "elapsed_ms", "generation", "config_generation"] {
      guard let number = object[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        let value = unsignedDecimal(number.stringValue)
      else { continue }
      fields[key] = value
    }
    record("core_phase", fields: fields)
  }

  static func appGroupIdentifier(bundleIdentifier: String) -> String? {
    let host = bundleIdentifier.hasSuffix(".NECore")
      ? String(bundleIdentifier.dropLast(".NECore".count)) : bundleIdentifier
    return host.isEmpty ? nil : "group.\(host)"
  }

  #if SWITCH_DIAGNOSTICS_TESTING
  private static var testDirectory: URL?
  private static var testBundleIdentifier: String?

  static func setTestDirectory(_ directory: URL, bundleIdentifier: String) {
    queue.sync {
      testDirectory = directory
      testBundleIdentifier = bundleIdentifier
    }
  }
  #endif

  private static func fileURL() -> URL? {
    #if SWITCH_DIAGNOSTICS_TESTING
    let bundle = testBundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
    var directory = testDirectory
    #else
    let bundle = Bundle.main.bundleIdentifier ?? ""
    var directory: URL?
    #endif
    guard let group = appGroupIdentifier(bundleIdentifier: bundle) else { return nil }
    if directory == nil {
      directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    let process = bundle.hasSuffix(".NECore") ? "NECore" : "Runner"
    return directory?.appendingPathComponent("ios-switch-\(process).log")
  }

  private static func safeValue(_ value: String, for key: String) -> String? {
    guard value.utf8.count <= 128 else { return nil }
    if numericFields.contains(key) { return unsignedDecimal(value) }
    switch key {
    case "error_code":
      let digits = value.hasPrefix("-") ? value.dropFirst() : value[...]
      guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
        let number = Int64(value) else { return nil }
      return String(number)
    case "method": return methods.contains(value) || value == "unknown" ? value : nil
    case "core_phase": return phases.contains(value) ? value : nil
    case "request_id", "parent_request_id", "profile_digest":
      let bytes = value.utf8
      return bytes.count == 16 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        ? value : nil
    case "attempt_id":
      return UUID(uuidString: value)?.uuidString
    case "status_before", "status_after":
      return values["status"]!.contains(value) ? value : nil
    case "route_before", "route_after":
      return values["route"]!.contains(value) ? value : nil
    case "reason":
      if let number = unsignedDecimal(value), let code = UInt64(number), code <= 255 { return number }
      return values[key]!.contains(value) ? value : nil
    default:
      return values[key]?.contains(value) == true ? value : nil
    }
  }

  private static func unsignedDecimal(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 20,
      value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value)
    else { return nil }
    return String(number)
  }

  private static func append(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
      guard manager.createFile(atPath: url.path, contents: nil) else { return }
    }
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size > UInt64(maxBytes - data.count) {
      let retain = min(size, UInt64(maxBytes / 2))
      try handle.seek(toOffset: size - retain)
      let tail = try handle.read(upToCount: Int(retain)) ?? Data()
      let retained: Data
      if let first = tail.firstIndex(of: 0x0A), let last = tail.lastIndex(of: 0x0A), first < last {
        retained = Data(tail[tail.index(after: first)...last])
      } else {
        retained = Data()
      }
      try handle.truncate(atOffset: 0)
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: retained)
    }
    try handle.write(contentsOf: data)
  }

  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / (1024 * 1024) : -1
  }
}

// Independent diagnostic storage. This is not a shared-container repair.
extension SwitchDiagnostics {
  static let iPadSchema = "iPadDiagnostic-v1"
  private static let iPadQueue = DispatchQueue(label: "com.follow.clash.ipad-diagnostic", qos: .utility)
  private static let iPadLock = NSLock()
  static let maxPendingJobs = 64
  static let maxPendingBytes = 64 * 1024
  private static var pendingJobs = 0
  private static var pendingBytes = 0
  private static var droppedJobs = 0
  private static var capabilityPending = false
  private static var iPadMemory: [String] = []
  private static var iPadPinned: [String: String] = [:]
  private static let iPadStages: Set<String> = ["runner_launch", "loader_before", "loader_after", "provider_init", "provider_entry", "manager_load", "manager_selected", "save", "reload", "start_call", "start_throw", "disconnect", "rpc_publication", "vpn_options", "setup_params", "network_settings", "tunnel_fd", "init_core", "quick_setup", "start_tun", "command_server", "completion", "cleanup", "cancelled", "stop", "capabilities"]
  private static let iPadBooleans: Set<String> = ["success", "loader_exists", "loader_loaded", "group_available", "directory_readable", "directory_writable", "probe_success", "defaults_available", "snapshot_exists", "snapshot_object", "vpn_options_object", "setup_exists", "setup_object", "enabled", "protocol_exists", "provider_matches", "bundle_relation"]
  private static let iPadTokens: Set<String> = ["error_domain", "underlying_domain", "provider_stage", "observation"]
  #if SWITCH_DIAGNOSTICS_TESTING
  private static var testLocalDirectory: URL?
  private static var testSharedUnavailable = false
  static func setIPadTestStorage(local: URL?, sharedUnavailable: Bool) {
    iPadQueue.sync { testLocalDirectory = local; testSharedUnavailable = sharedUnavailable; iPadMemory.removeAll(); iPadPinned.removeAll() }
  }
  static func iPadQueueBudget() -> (jobs: Int, bytes: Int, dropped: Int) {
    iPadLock.lock(); defer { iPadLock.unlock() }; return (pendingJobs, pendingBytes, droppedJobs)
  }
  static func holdIPadQueue(_ semaphore: DispatchSemaphore) { iPadQueue.async { semaphore.wait() } }
  #endif
  private static func localIPadURL() -> URL? {
    #if SWITCH_DIAGNOSTICS_TESTING
    return testLocalDirectory?.appendingPathComponent("ipad-diagnostic-local.jsonl")
    #else
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let root = base.appendingPathComponent("iPadDiagnostics", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("ipad-diagnostic-local.jsonl")
    #endif
  }
  private static func iPadSharedRoot() -> URL? {
    #if SWITCH_DIAGNOSTICS_TESTING
    if testSharedUnavailable { return nil }
    if let testDirectory { return testDirectory }
    #endif
    guard let group = appGroupIdentifier(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
  }
  static func iPadErrorFields(_ source: Error?) -> [String: String] {
    guard let error = source as NSError? else { return ["error_domain": "none", "observation": "no_error_no_entry_proof"] }
    func domain(_ value: String) -> String {
      // Apple constants, not guessed domain spellings; unknown text is never exported.
      if #available(iOS 16.0, macOS 13.0, *), value == NetworkExtension.NEVPNConnectionErrorDomain { return "NEVPNConnectionErrorDomain" }
      switch value {
      case NetworkExtension.NEVPNErrorDomain: return "NEVPNErrorDomain"
      case NSPOSIXErrorDomain: return "NSPOSIXErrorDomain"
      case NSCocoaErrorDomain: return "NSCocoaErrorDomain"
      case NSURLErrorDomain: return "NSURLErrorDomain"
      case "com.flclashyf.iPadDiagnostic": return "provider_diagnostic"
      default: return "unknown"
      }
    }
    var fields = ["error_domain": domain(error.domain), "error_code": String(error.code), "observation": "system_error_entry_unknown"]
    var current: NSError? = error
    var seen = Set<ObjectIdentifier>()
    for _ in 0..<4 {
      guard let item = current, seen.insert(ObjectIdentifier(item)).inserted else { break }
      if item.domain == "com.flclashyf.iPadDiagnostic", let stage = providerStages[item.code] {
        fields["provider_stage"] = stage; fields["observation"] = "provider_entry_proved"
      }
      guard let underlying = item.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
      fields["underlying_domain"] = domain(underlying.domain)
      fields["underlying_code"] = String(underlying.code)
      current = underlying
    }
    return fields
  }
  static let providerStages: [Int: String] = [1:"rpc_publication", 2:"vpn_options", 3:"network_settings", 4:"tunnel_fd", 5:"quick_setup", 6:"start_tun", 7:"command_server", 8:"cancelled", 9:"completion"]
  static func recordIPad(_ stage: String, fields: [String: String] = [:]) {
    guard iPadStages.contains(stage) else { return }
    var safe: [String: String] = ["schema": iPadSchema, "stage": stage, "process_id": processID, "timestamp": ISO8601DateFormatter().string(from: Date())]
    if stage == "provider_entry" || stage == "runner_launch" {
      let identity = iPadIdentity()
      if let token = identity.split(separator: " ").first(where: { $0.hasPrefix("image_uuid=") }),
        let uuid = UUID(uuidString: String(token.dropFirst("image_uuid=".count))) { safe["image_uuid"] = uuid.uuidString }
    }
    for (key, value) in fields.prefix(32) {
      guard value.utf8.count <= 128 else { continue }
      if iPadBooleans.contains(key), ["true", "false"].contains(value) { safe[key] = value }
      if ["generation", "error_code", "underlying_code", "count"].contains(key), let n = Int64(value) { safe[key] = String(n) }
      if key == "attempt_id", let uuid = UUID(uuidString: value) { safe[key] = uuid.uuidString }
      if iPadTokens.contains(key), Set(["none", "unknown", "NEVPNErrorDomain", "NEVPNConnectionErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain", "NSURLErrorDomain", "provider_diagnostic", "provider_entry_proved", "system_error_entry_unknown", "no_error_no_entry_proof"] + Array(providerStages.values)).contains(value) { safe[key] = value }
    }
    guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), bytes.count <= 4096, let line = String(data: bytes, encoding: .utf8) else { return }
    iPadLock.lock()
    guard pendingJobs < maxPendingJobs, pendingBytes + bytes.count <= maxPendingBytes else { droppedJobs += 1; iPadLock.unlock(); return }
    pendingJobs += 1; pendingBytes += bytes.count; iPadLock.unlock()
    iPadQueue.async {
      defer { iPadLock.lock(); pendingJobs -= 1; pendingBytes -= bytes.count; iPadLock.unlock() }
      if ["runner_launch", "provider_init", "provider_entry", "disconnect", "completion", "capabilities"].contains(stage) { iPadPinned[stage] = line }
      iPadMemory.append(line)
      if iPadMemory.count > 256 { iPadMemory.removeFirst(iPadMemory.count - 256) }
      if let url = localIPadURL() { appendIPad(bytes, to: url) }
      if let root = iPadSharedRoot() {
        let role = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".NECore") ? "NECore" : "Runner"
        appendIPad(bytes, to: root.appendingPathComponent("ipad-diagnostic-\(role).jsonl"))
      }
    }
  }
  private static func appendIPad(_ bytes: Data, to url: URL) {
    var line = bytes; line.append(10)
    let fm = FileManager.default
    do {
      if !fm.fileExists(atPath: url.path) { guard fm.createFile(atPath: url.path, contents: nil) else { return } }
      let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
      let size = try handle.seekToEnd()
      if size + UInt64(line.count) > 256 * 1024 {
        try handle.seek(toOffset: size > 128 * 1024 ? size - 128 * 1024 : 0)
        let tail = try handle.read(upToCount: 128 * 1024) ?? Data()
        let retained = tail.firstIndex(of: 10).map { Data(tail[tail.index(after: $0)...]) } ?? Data()
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0); try handle.write(contentsOf: retained)
      }
      try handle.write(contentsOf: line)
    } catch { /* Memory evidence remains available. Never alter product failure. */ }
  }
  static func recordIPadCapabilities() {
    iPadLock.lock()
    guard !capabilityPending else { iPadLock.unlock(); return }
    capabilityPending = true; iPadLock.unlock()
    // At most one capability job in addition to the bounded record lane.
    iPadQueue.async {
      defer { iPadLock.lock(); capabilityPending = false; iPadLock.unlock() }
      let root = iPadSharedRoot()
      var probe = false
      if let root {
        let marker = root.appendingPathComponent(".ipad-diagnostic-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        if (try? Data([1]).write(to: marker, options: .atomic)) != nil { probe = (try? Data(contentsOf: marker)) == Data([1]) }
      }
      let group = appGroupIdentifier(bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
      let defaults = group.flatMap { UserDefaults(suiteName: $0) }
      let snapshot = defaults?.data(forKey: "sharedState")
      let object = snapshot.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let setup = defaults?.data(forKey: "setupParams")
      recordIPad("capabilities", fields: ["group_available": String(root != nil), "directory_readable": String(root.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false), "directory_writable": String(root.map { FileManager.default.isWritableFile(atPath: $0.path) } ?? false), "probe_success": String(probe), "defaults_available": String(defaults != nil), "snapshot_exists": String(snapshot != nil), "snapshot_object": String(object != nil), "vpn_options_object": String(object?["vpnOptions"] is [String: Any]), "setup_exists": String(setup != nil), "setup_object": String(setup.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } != nil)])
    }
  }
  static func exportIPadDiagnostics(_ completion: @escaping (String) -> Void) {
    iPadQueue.async {
      func read(_ url: URL?) -> (String, String) {
        guard let url else { return ("unavailable", "") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("unreadable_or_absent", "") }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024), let text = String(data: data, encoding: .utf8) else { return ("unreadable", "") }
        let validated = text.split(separator: "\n").compactMap { line -> String? in
          guard line.utf8.count <= 4096,
            let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String],
            row["schema"] == iPadSchema, let stage = row["stage"], iPadStages.contains(stage),
            let timestamp = row["timestamp"], ISO8601DateFormatter().date(from: timestamp) != nil,
            let process = row["process_id"], UUID(uuidString: process) != nil
          else { return nil }
          var safe = ["schema": iPadSchema, "stage": stage, "timestamp": timestamp, "process_id": process]
          let tokens = Set(["none", "unknown", "NEVPNErrorDomain", "NEVPNConnectionErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain", "NSURLErrorDomain", "provider_diagnostic", "provider_entry_proved", "system_error_entry_unknown", "no_error_no_entry_proof"] + Array(providerStages.values))
          for (key, value) in row {
            if iPadBooleans.contains(key), ["true", "false"].contains(value) { safe[key] = value }
            if ["generation", "error_code", "underlying_code", "count"].contains(key), let n = Int64(value) { safe[key] = String(n) }
            if ["attempt_id", "image_uuid"].contains(key), let uuid = UUID(uuidString: value) { safe[key] = uuid.uuidString }
            if iPadTokens.contains(key), tokens.contains(value) { safe[key] = value }
          }
          guard let encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) else { return nil }
          return String(data: encoded, encoding: .utf8)
        }.joined(separator: "\n")
        return ("readable", validated)
      }
      let runnerLocal = read(localIPadURL())
      let shared = iPadSharedRoot()
      let sharedSource = read(shared?.appendingPathComponent("ipad-diagnostic-NECore.jsonl"))
      iPadLock.lock(); let dropped = droppedJobs; iPadLock.unlock()
      let result = "===== \(iPadSchema) =====\n" + iPadIdentity() + "\ncontainer_identity=not_proved signing_entitlements=unavailable capability_scope=observed_only\nrunnerLocal=\(runnerLocal.0) sharedSource=\(sharedSource.0) dropped=\(dropped)\n" + (runnerLocal.0 == "readable" ? runnerLocal.1 : iPadMemory.joined(separator: "\n")) + "\n===== pinned startup window =====\n" + iPadPinned.keys.sorted().compactMap { iPadPinned[$0] }.joined(separator: "\n") + "\n===== NE shared diagnostic (NE private fallback is not app-readable) =====\n" + sharedSource.1 + "\nno_provider_evidence=entry_unknown_not_proof_of_no_launch\n"
      completion(result)
    }
  }
  private static func iPadIdentity() -> String {
    var imageUUID = "unavailable"
    if let header = _dyld_get_image_header(0) {
      let base = UnsafeRawPointer(header)
      var offset = MemoryLayout<mach_header_64>.size
      for _ in 0..<min(Int(header.pointee.ncmds), 4096) {
        let command = base.advanced(by: offset).load(as: load_command.self)
        guard command.cmdsize >= MemoryLayout<load_command>.size else { break }
        if command.cmd == LC_UUID {
          let value = base.advanced(by: offset).load(as: uuid_command.self).uuid
          imageUUID = UUID(uuid: value).uuidString; break
        }
        offset += Int(command.cmdsize)
      }
    }
    let bundle = Bundle.main
    let mainID = bundle.bundleIdentifier ?? ""
    let neID = bundle.builtInPlugInsURL.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }?.compactMap { Bundle(url: $0)?.bundleIdentifier }.first { $0.hasSuffix(".NECore") }
    let bundleRelation = mainID.hasSuffix(".NECore") || neID == mainID + ".NECore"
    let embeddedProfile = bundle.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    let signatureDirectory = FileManager.default.fileExists(atPath: bundle.bundleURL.appendingPathComponent("_CodeSignature/CodeResources").path)
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if canImport(UIKit)
    let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "other"
    #else
    let deviceClass = "mac_gate"
    #endif
    return "schema=\(iPadSchema) source_base=de6517d43c3a3277df4f0ce14c42b3f791f9fb05 image_uuid=\(imageUUID) os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) device_class=\(deviceClass) bundle_relation=\(bundleRelation) embedded_profile=\(embeddedProfile) signature_resources=\(signatureDirectory) signing_groups_count=unavailable signing_vpn_entitlement=unavailable"
  }
}
