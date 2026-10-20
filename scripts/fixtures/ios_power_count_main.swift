// Full production CoreMessageRouter + coordinator + retry + diagnostics.
// Only the transport/controller and ObjC bridge are boundary doubles.
import Foundation
import CoreFoundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = CommandLine.arguments[2]
enum PowerBoundary {
  static func containerURL(forSecurityApplicationGroupIdentifier: String) -> URL? { root }
}
enum PowerProbe { static func bump(_ key: String) {} }
enum TunnelTarget { case running, stopped }
struct ProviderMessageError: Error { let code: String; let message: String }
@MainActor final class TunnelController {
  var shouldFail = false
  var requests: [Data] = []
  func isCoreActive() async -> Bool { true }
  func captureProviderOwner() -> ProviderOwner { ProviderOwner(clientEpoch: 0, attempt: nil) }
  func validateProviderOwner(_ owner: ProviderOwner) throws {}
  func beginConfigurationApply() -> UInt64 { 0 }
  func finishConfigurationApply(generation: UInt64, success: Bool) {}
  func sendProviderMessage(_ data: Data) async throws -> String {
    requests.append(data)
    if shouldFail { throw ProviderMessageError(code: "network_extension_timeout", message: "fixture") }
    return #"{"result":123,"error":null}"#
  }
}
enum IOSCoreBridge {
  static var calls = 0
  static func invokeMethod(_ data: String, completion: @escaping (String?) -> Void) {
    calls += 1; completion(#"{"result":999,"error":null}"#)
  }
}
func finish(_ failures: [String]) -> Never {
  let row: [String: Any] = ["fixture": "ios-power-count-v1", "mode": mode,
    "status": failures.isEmpty ? "pass" : "semantic_failure", "failures": failures]
  print(String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
  exit(failures.isEmpty ? 0 : 1)
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
SwitchDiagnostics.setTestDirectory(root, bundleIdentifier: "audit.count.Runner")
let payload = Data(#"{"method":"getConnectionsCount","id":"count-only","arguments":null}"#.utf8)
if mode == "count-readonly" {
  finish(ProviderReadRetry.isReadOnlyMethod("getConnectionsCount") ? [] : ["count_readonly_classification"])
}
if mode == "count-diagnostic" {
  finish(SwitchDiagnostics.method(payload) == "getConnectionsCount" ? [] : ["count_diagnostic_allowlist"])
}
Task { @MainActor in
  let controller = TunnelController()
  let router = CoreMessageRouter(tunnelController: controller)
  router.updateTunnelState(.running)
  controller.shouldFail = mode == "count-no-fallback"
  let response = await router.invoke(payload)
  var failures: [String] = []
  if mode == "count-no-fallback" {
    if IOSCoreBridge.calls != 0 { failures.append("count_ne_failure_fell_back_to_app") }
    let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any]
    if ((object?["error"] as? [String: Any])?["code"] as? String) != "network_extension_timeout" {
      failures.append("count_ne_error_not_preserved")
    }
  } else if mode == "count-integer" {
    let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any]
    if (object?["result"] as? Int) != 123 || IOSCoreBridge.calls != 0 { failures.append("count_integer_passthrough") }
  } else { failures.append("unknown_count_mode") }
  if controller.requests != [payload] { failures.append("count_changed_or_full_connections_requested") }
  finish(failures)
}
dispatchMain()
