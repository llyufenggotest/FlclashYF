// Framework/native boundary doubles only; stores and lifecycle/routing methods
// are production sources. Isolated UserDefaults suite is removed on exit.
import Foundation
import CoreFoundation
import Darwin
let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
var fixtureContainer: URL? = fixtureRoot
extension FileManager {
  func testContainerURL(forSecurityApplicationGroupIdentifier: String) -> URL? { fixtureContainer }
}
enum UIApplication {
  static let didBecomeActiveNotification = Notification.Name("test.active")
  static let didEnterBackgroundNotification = Notification.Name("test.background")
  static let willEnterForegroundNotification = Notification.Name("test.foreground")
}
struct WidgetCenter {
  static let shared = WidgetCenter()
  func reloadTimelines(ofKind: String) {}
  func reloadAllTimelines() {}
}
struct ControlCenter {
  static let shared = ControlCenter()
  func reloadControls(ofKind: String) {}
}
enum NEVPNStatus: Int { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
enum NEProviderStopReason: Int { case none, userInitiated }
class NEVPNConnection: NSObject {
  var status = NEVPNStatus.connected
  weak var manager: NETunnelProviderManager?
  func startVPNTunnel() throws { status = .connecting }
  func stopVPNTunnel() { status = .disconnected }
}
class NEVPNProtocol: NSObject {}
final class NETunnelProviderProtocol: NEVPNProtocol {
  var providerBundleIdentifier: String?
  var serverAddress: String?
  var disconnectOnSleep = false
  var includeAllNetworks = false, excludeLocalNetworks = true, excludeAPNs = true
  var excludeCellularServices = true, enforceRoutes = false, excludeDeviceCommunication = true
}
class NEOnDemandRule: NSObject {}
final class NEOnDemandRuleDisconnect: NEOnDemandRule { var ssidMatch: [String]? }
final class NEOnDemandRuleConnect: NEOnDemandRule {}
final class NETunnelProviderManager: NSObject {
  let connection = NEVPNConnection()
  var protocolConfiguration: NEVPNProtocol?
  var localizedDescription: String?
  var isEnabled = true, isOnDemandEnabled = false
  var onDemandRules: [NEOnDemandRule]?
  static var heldLoad: (([NETunnelProviderManager]?, Error?) -> Void)?
  static var holdLoads = false
  static var managers: [NETunnelProviderManager] = []
  override init() { super.init(); connection.manager = self }
  static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
    if holdLoads { heldLoad = completionHandler } else { completionHandler(managers, nil) }
  }
  func saveToPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
  func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}
extension Notification.Name { static let NEVPNStatusDidChange = Notification.Name("test.status") }
let NEVPNErrorDomain = "test.nevpn"
enum NEVPNError: Int { case configurationInvalid = 1, configurationStale, configurationUnknown }
enum SwitchDiagnostics {
  static let processID = "native-fixture"
  static func record(_ phase: String, fields: [String: String] = [:]) {}
  static func requestID(_ data: Data) -> String {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String ?? "unknown"
  }
  static func method(_ data: Data) -> String {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["method"] as? String ?? "unknown"
  }
}
enum IOSCoreBridge {
  static var heldApp: ((String?) -> Void)?
  static var holdApp = false
  static func invokeMethod(_ data: String, completion: @escaping (String?) -> Void) {
    if holdApp { heldApp = completion } else { completion("{\"result\":\"\",\"error\":null}") }
  }
}
#if PROVIDER_FIXTURE
// The actual provider invokes these held external operations.
class NEPacketTunnelProvider: NSObject {
  var heldSettings: ((Error?) -> Void)?
  func setTunnelNetworkSettings(_ settings: NSObject, completionHandler: @escaping (Error?) -> Void) { heldSettings = completionHandler }
  func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {}
  func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {}
  func handleAppMessage(_ data: Data, completionHandler: ((Data?) -> Void)?) {}
  func sleep(completionHandler: @escaping () -> Void) {}
  func wake() {}
}
final class PacketTunnelNetworkConfiguration {
  func makeSettings(for options: PacketTunnelVPNOptions) -> NSObject { NSObject() }
  func tunnelFileDescriptor() -> Int32? { 10 }
  func tunAddress(for options: PacketTunnelVPNOptions) -> String { "172.19.0.1" }
  func tunDNS(for options: PacketTunnelVPNOptions) -> String { "172.19.0.2" }
}
final class NECoreEventQueue {
  init(sharedStateStore: PacketTunnelSharedStateStore) {}
  func start() {}
  func stop() {}
  func markCoreResponsive() {}
}
final class NativeResourceHeartbeat {
  static func footprintSampleMB() -> Int { 0 }
  func start() {}
  func retire(_ callback: @escaping () -> Void) { callback() }
}
final class NativeStopCompletion {
  let completion: () -> Void
  init(completion: @escaping () -> Void) { self.completion = completion }
  func finish() { completion() }
}
final class NativeDiagnosticLog {
  static let shared = NativeDiagnosticLog()
  func append(_ message: String) {}
}
enum NECoreBridge {
  static var heldSetup: ((Data?) -> Void)?
  static func quickSetup(withInitParams: String, setupParams: Data, completion: @escaping (Data?) -> Void) { heldSetup = completion }
  static func startTun(withFileDescriptor: Int32, options: Data) -> Bool { true }
  static func stopTun() {}
  static func invokeMethod(_ data: Data, completion: @escaping (Data?) -> Void) { completion(nil) }
}
final class PacketTunnelCommandServer {
  init(sharedStateStore: PacketTunnelSharedStateStore, invoke: @escaping (Data, @escaping (Data?) -> Void) -> Void) {}
  func start(attempt: UUID) -> Bool { RPCSession(version: RPCWire.version, attempt: attempt, ready: true).publish(to: fixtureContainer) }
  func stop() {}
}
#endif
