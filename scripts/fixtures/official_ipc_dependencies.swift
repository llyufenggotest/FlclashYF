import Foundation
import os

class NEPacketTunnelProvider {
  func handleAppMessage(_ data: Data, completionHandler: ((Data?) -> Void)?) {}
}
struct FixtureQueue { func markCoreResponsive() {} }
struct FixtureStore { func clearConfigurationRequestApplied() {} }
enum SwitchDiagnostics {
  static func requestID(_ data: Data) -> String { "fixture" }
  static func method(_ data: Data) -> String { "fixture" }
  static func responseErrorType(_ data: Data?, method: String) -> String { "none" }
  static func record(_ phase: String, fields: [String: String] = [:]) {}
}
enum NECoreBridge {
  static var calls = 0
  static let reply = Data("unaltered-core-reply".utf8)
  static func invokeMethod(_ data: Data, completion: @escaping (Data?) -> Void) {
    calls += 1; completion(reply)
  }
}
class FixtureProvider: NEPacketTunnelProvider {
  let lifecycleGeneration = UUID()
  let eventQueue = FixtureQueue()
  let sharedStateStore = FixtureStore()
  let logger = Logger(subsystem: "fixture", category: "ipc")
  func configProbe() -> String { "fixture" }
  func methodErrorResponse(messageData: Data, code: String, message: String) -> Data? { nil }
  // EXACT_HANDLER
}

enum NEVPNStatus: Int { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
class NEVPNConnection: NSObject {}
final class NETunnelProviderSession: NEVPNConnection {
  var status = NEVPNStatus.disconnected
  static var sends = 0
  static var callback: ((Data?) -> Void)?
  static var lastRequest = Data()
  static var mode = "echo"
  func sendProviderMessage(_ request: Data, responseHandler: ((Data?) -> Void)? = nil) throws {
    Self.sends += 1; Self.lastRequest = request; Self.callback = responseHandler
    switch Self.mode {
    case "echo": _ = OfficialIPCWire.intercept(request, completion: responseHandler)
    case "nil": responseHandler?(nil)
    case "mismatch": responseHandler?(Data("bad".utf8))
    case "wrong-nonce": _ = OfficialIPCWire.intercept(OfficialIPCWire.request(nonce: UUID()), completion: responseHandler)
    case "wrong-receipt": responseHandler?(request + Data(repeating: 0, count: OfficialIPCWire.receipt.count) + Data(OfficialIPCWire.imageUUID().utf8))
    case "oversize": responseHandler?(Data(repeating: 0, count: 4097))
    case "error": throw NSError(domain: "secret/raw/path", code: 73, userInfo: [NSLocalizedDescriptionKey: "DO_NOT_EXPORT"])
    case "status":
      status = .connecting
      NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self)
      _ = OfficialIPCWire.intercept(request, completion: responseHandler)
    default: break
    }
  }
}
final class NETunnelProviderProtocol { var providerBundleIdentifier: String? = "fixture.NECore" }
final class NETunnelProviderManager {
  var protocolConfiguration: Any? = NETunnelProviderProtocol()
  var connection: NEVPNConnection = NETunnelProviderSession()
  static var managers: [NETunnelProviderManager] = []
  static var hold = false
  static var loadCallback: (([NETunnelProviderManager]?, Error?) -> Void)?
  static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
    loadCallback = completionHandler
    if !hold { completionHandler(managers, nil) }
  }
}
extension Notification.Name { static let NEVPNStatusDidChange = Notification.Name("fixture.status") }
