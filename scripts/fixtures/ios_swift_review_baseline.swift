// Immutable 65e review baseline: real source, no implementation transforms.
import Foundation
import CoreFoundation
struct PacketTunnelEnvironment {
  static let appGroupIdentifier = "test.baseline"
  static let extensionBundleIdentifier = "test.baseline"
  static let eventNotificationName = "test.baseline"
}
enum SwitchDiagnostics { static let processID = "baseline" }
final class SharedStateStore {
  let root: URL
  let eventNotificationName = "test.baseline.runner"
  init(_ root: URL) { self.root = root }
  func eventQueueDirectory() -> URL? { root }
}
#if BASELINE_RUNNER
enum IOSCoreBridge { static func setEventListener(_ callback: ((String?) -> Void)?) {} }
#endif
func expected(_ detail: String) -> Never { print("EXPECTED_REVIEW_RED \(detail)"); exit(1) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
#if BASELINE_RUNNER
Task { @MainActor in
  for i in 0..<100 { try! "critical-\(i)".write(to: root.appendingPathComponent("\(i).json"), atomically: true, encoding: .utf8) }
  var delivered = 0
  // No ACK at all. The real baseline sends all 100 anyway.
  let relay = CoreEventRelay(sharedStateStore: SharedStateStore(root), sendEvent: { _, _ in delivered += 1 })
  relay.start()
  if delivered > 1 { expected("M03 Flutter_window=\(delivered) wanted=1") }
  exit(0)
}
dispatchMain()
#elseif BASELINE_LOG
let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), mainReturned = DispatchSemaphore(value: 0)
let log = NativeDiagnosticLog.shared
log.setTestURL(root.appendingPathComponent("log"), beforeWrite: { entered.signal(); release.wait() })
log.append("hold", discardable: true)
precondition(entered.wait(timeout: .now() + 5) == .success)
DispatchQueue.main.async { log.append("critical-main"); mainReturned.signal() }
DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
  if mainReturned.wait(timeout: .now() + 0.1) == .timedOut { expected("M01 main critical blocked by held writer") }
  exit(0)
}
dispatchMain()
#else
let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), reply = DispatchSemaphore(value: 0)
NECoreBridge.setEventListener { _ in entered.signal(); release.wait() }
DispatchQueue.global().async { "critical".withCString { testEmitEvent($0) } }
precondition(entered.wait(timeout: .now() + 5) == .success)
NECoreBridge.invokeMethod(Data("request".utf8)) { _ in reply.signal() }
if reply.wait(timeout: .now() + 0.2) == .timedOut { expected("M02 real ObjC shared callback blocked by event producer") }
exit(0)
#endif
