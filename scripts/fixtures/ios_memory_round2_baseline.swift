// Actual event/RPC baseline probes; dependency doubles only.
import Foundation
import CoreFoundation
struct PacketTunnelEnvironment {
  static let extensionBundleIdentifier = "test.round2.baseline"
  static let commandNotificationName = "test.round2.baseline.command"
  static let eventNotificationName = "test.round2.baseline.event"
}
final class PacketTunnelSharedStateStore {
  let root: URL
  init(_ root: URL) { self.root = root }
  func appGroupDirectory() -> URL? { root }
  func clearConfigurationRequestApplied() {}
  func markConfigurationRequestApplied(_ id: String) {}
}
enum SwitchDiagnostics {
  static func requestID(_ data: Data) -> String { "test" }
  static func method(_ data: Data) -> String { "getProxies" }
  static func record(_ phase: String, fields: [String: String]) {}
}
enum NECoreBridge {
  static var listener: ((Data?) -> Void)?
  static func setEventListener(_ callback: ((Data?) -> Void)?) { listener = callback }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = PacketTunnelSharedStateStore(root)
if CommandLine.arguments[1] == "event" {
  let events = NECoreEventQueue(sharedStateStore: store)
  events.start()
  for index in 0..<30 {
    NECoreBridge.listener!(try JSONSerialization.data(withJSONObject: ["method": "message", "arguments": [["type": "delay", "data": index]]]))
  }
  events.stop() // real production barrier
  let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("core-events").path).filter { $0.hasSuffix(".json") }
  if files.count != 30 {
    print("EXPECTED_BASELINE_RED critical_ack_lost count=\(files.count) wanted=30")
    exit(1)
  }
  print("PASS critical ack retention")
} else {
  let lock = NSLock()
  var calls = 0
  var callbacks: [(Data?) -> Void] = []
  let server = PacketTunnelCommandServer(sharedStateStore: store, invoke: { _, callback in
    lock.lock(); calls += 1; callbacks.append(callback); lock.unlock()
  })
  let requests = root.appendingPathComponent("core-rpc/req")
  try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
  for index in 0..<16 { try Data("request".utf8).write(to: requests.appendingPathComponent("\(index).req")) }
  server.start()
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    lock.lock(); let current = calls; lock.unlock()
    if current == 16 { break }
    Thread.sleep(forTimeInterval: 0.01)
  }
  server.stop()
  lock.lock(); let current = calls; lock.unlock()
  if current > 4 {
    print("EXPECTED_BLOCKER_RED actual_callback_pending=\(current) exceeds_client_slots=4")
    exit(1)
  }
  print("UNEXPECTED_GREEN_OR_TIMEOUT calls=\(current)")
}
