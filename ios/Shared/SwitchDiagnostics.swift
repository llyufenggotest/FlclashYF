import CoreFoundation
import CryptoKit
import Darwin
import Foundation

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
    "getTotalTraffic", "resetTraffic", "asyncTestDelay", "getConnections", "closeConnections",
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
    "app_memory_warning",
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
                   "configuration_request_failed", "network_extension_error", "invalid_method_call"],
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

  static func record(_ event: String, fields: [String: String] = [:]) {
    queue.sync {
      guard let url = fileURL() else { return }
      var entry: [String: Any] = [
        "timestamp": formatter.string(from: Date()),
        "uptime_ms": ProcessInfo.processInfo.systemUptime * 1000,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "process_id": processID,
        "footprint_mb": footprintMB(),
        "event": events.contains(event) ? event : "unknown",
      ]
      for (key, value) in fields {
        if let safe = safeValue(value, for: key) { entry[key] = safe }
      }
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
