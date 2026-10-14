// Compiles the exact production Swift and BOTH real ObjC bridges. Go C exports
// alone are dependencies doubled. It is not a Go occupancy/total RSS test.
import Foundation
import CoreFoundation
struct PacketTunnelEnvironment {
  static let appGroupIdentifier = "test.review"
  static let extensionBundleIdentifier = "test.review"
  static let eventNotificationName = "test.review.event"
}
enum SwitchDiagnostics { static let processID = "test-review" }
final class PacketTunnelSharedStateStore {
  let root: URL
  init(_ root: URL) { self.root = root }
  func appGroupDirectory() -> URL? { root }
}
final class SharedStateStore {
  let root: URL
  init(_ root: URL) { self.root = root }
  let eventNotificationName = "test.review.runner"
  func eventQueueDirectory() -> URL? { root }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError(message) }
}
func waitMain(_ predicate: () -> Bool, seconds: Double = 5) {
  let end = Date().addingTimeInterval(seconds)
  while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
  check(predicate(), "main wait timed out")
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let log = NativeDiagnosticLog.shared
let writerEntered = DispatchSemaphore(value: 0), writerRelease = DispatchSemaphore(value: 0)
let logLock = NSLock(); var first = true
log.setTestURL(root.appendingPathComponent("diagnostics"), beforeWrite: {
  logLock.lock(); let hold = first; first = false; logLock.unlock()
  if hold { writerEntered.signal(); check(writerRelease.wait(timeout: .now() + 15) == .success, "log hold timeout") }
})
log.append("hold")
check(writerEntered.wait(timeout: .now() + 5) == .success, "writer missing")
// Real main admission must return WHILE writer is still held.
for _ in 0..<100 { log.append("critical-main") }
let budget = log.testCriticalPending()
check(budget.jobs <= NativeDiagnosticLog.maxCriticalJobs && budget.bytes <= NativeDiagnosticLog.maxCriticalBytes && budget.dropped > 0, "critical lane not bounded")
let hb = NativeResourceHeartbeat(reclaim: {}, sample: { (0, 0, 0) })
hb.start(); let owner = hb.testOwner(); hb.testTick(owner: owner); hb.stop()
let completionLock = NSLock(); var completionCount = 0
func completed() -> Int { completionLock.lock(); defer { completionLock.unlock() }; return completionCount }
let completion = NativeStopCompletion(deadline: 0.05) { completionLock.lock(); completionCount += 1; completionLock.unlock() }
waitMain { completed() == 1 }
completion.finish(); check(completed() == 1, "completion duplicate")
writerRelease.signal(); log.flush()
print("PASS M01 held diagnostic writer: main heartbeat stop + independent completion, reserved budget/drop counters")

// Hold actual GC. Retirement is nonblocking; its completion stays closed until
// native work exits. The provider's separate coreReclaimRetiring gate owns B.
let gcEntered = DispatchSemaphore(value: 0), gcRelease = DispatchSemaphore(value: 0)
let gcRetired = DispatchSemaphore(value: 0)
let gc = NativeResourceHeartbeat(reclaim: {
  gcEntered.signal(); check(gcRelease.wait(timeout: .now() + 10) == .success, "GC hold timeout")
}, sample: { (40, 40, 40) })
gc.start(); check(gcEntered.wait(timeout: .now() + 5) == .success, "GC missing")
gc.retire { gcRetired.signal() }
check(gcRetired.wait(timeout: .now() + 0.1) == .timedOut, "old GC prematurely retired")
var sentinel = false; DispatchQueue.main.async { sentinel = true }; waitMain { sentinel }
gcRelease.signal(); check(gcRetired.wait(timeout: .now() + 5) == .success, "GC retirement missing")
gc.stop()
print("PASS M01 held GC: async retirement, main responsive, no early retirement")

let events = NECoreEventQueue(sharedStateStore: PacketTunnelSharedStateStore(root))
let eventEntered = DispatchSemaphore(value: 0), eventRelease = DispatchSemaphore(value: 0)
events.beforeWrite = { eventEntered.signal(); check(eventRelease.wait(timeout: .now() + 10) == .success, "event hold timeout") }
events.start()
let emitFinished = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
  "{\"method\":\"message\",\"arguments\":[{\"type\":\"delay\",\"data\":1}]}".withCString { testEmitEvent($0) }
  emitFinished.signal()
}
check(eventEntered.wait(timeout: .now() + 5) == .success, "event missing")
let rpcDone = DispatchSemaphore(value: 0)
NECoreBridge.invokeMethod(Data("request".utf8)) { _ in rpcDone.signal() }
check(rpcDone.wait(timeout: .now() + 1) == .success, "real ObjC RPC queue blocked by event I/O")
events.markCoreResponsive(); events.stop()
sentinel = false; DispatchQueue.main.async { sentinel = true }; waitMain { sentinel }
eventRelease.signal(); check(emitFinished.wait(timeout: .now() + 5) == .success, "producer stuck")
events.flush()
let durableEventFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("core-events").path)
check(durableEventFiles.count == 1, "admitted critical event lost at stop")
print("PASS M02 real NECoreBridge + event worker: held write leaves RPC/main/stop responsive, admitted critical durable")

let backlog = root.appendingPathComponent("runner")
try FileManager.default.createDirectory(at: backlog, withIntermediateDirectories: true)
for i in 0..<200 {
  let payload = "{\"method\":\"message\",\"arguments\":[{\"type\":\"log\"},{\"type\":\"loaded\",\"data\":\"\(String(repeating: "界", count: i == 0 ? 2 * 1024 * 1024 : i + 1))\"}]}"
  try payload.write(to: backlog.appendingPathComponent(String(format: "%06d.json", i)), atomically: true, encoding: .utf8)
}
let sendLock = NSLock()
var callbacks: [(Bool) -> Void] = [], lengths: [Int] = []
let relay = CoreEventRelay(sharedStateStore: SharedStateStore(backlog), sendEvent: { event, callback in
  sendLock.lock(); lengths.append(event.utf8.count); callbacks.append(callback); sendLock.unlock()
})
func sent() -> Int { sendLock.lock(); defer { sendLock.unlock() }; return callbacks.count }
func ack(_ i: Int, _ value: Bool) { sendLock.lock(); let cb = callbacks[i]; sendLock.unlock(); cb(value); relay.flush() }
relay.start(); relay.flush(); check(sent() == 1 && relay.testInFlight() == 1, "not single ACK window")
for _ in 0..<10000 {
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("test.review.runner" as CFString), nil, nil, true)
}
relay.flush(); check(sent() == 1, "notification flood bypassed ACK")
check(lengths[0] > 5 * 1024 * 1024, "large mixed payload truncated")
ack(0, false); check(FileManager.default.fileExists(atPath: backlog.appendingPathComponent("000000.json").path), "failure removed file")
relay.drainEventQueue(); relay.flush(); check(sent() == 2, "failed ACK not retryable")
// Reset + pathname replacement: old ACK must not delete replacement, even
// when successful. Occupancy remains one until the real old ACK returns.
relay.reset(); relay.flush()
let replacement = backlog.appendingPathComponent("000000.json")
try FileManager.default.removeItem(at: replacement)
try "replacement-critical".write(to: replacement, atomically: true, encoding: .utf8)
relay.drainEventQueue(); relay.flush(); check(sent() == 2, "reset freed actual Flutter slot")
ack(1, true); check(FileManager.default.fileExists(atPath: replacement.path), "late ACK deleted replacement")
check(sent() == 3, "new generation did not replay")
for i in 2..<202 { ack(i, true) }
let deleteFailureFile = backlog.appendingPathComponent("delete-failure.json")
try "delete-retry-critical".write(to: deleteFailureFile, atomically: true, encoding: .utf8)
relay.drainEventQueue(); relay.flush(); check(sent() == 203, "delete failure delivery missing")
relay.beforeDelete = { throw NSError(domain: "test", code: 1) }
ack(202, true)
check(FileManager.default.fileExists(atPath: deleteFailureFile.path), "delete failure lost durable file")
relay.beforeDelete = nil
relay.drainEventQueue(); relay.flush()
check(sent() == 203 && !FileManager.default.fileExists(atPath: deleteFailureFile.path), "ACK delete not retryable without redelivery")
// Duplicate success callback cannot delete anything in a later generation.
ack(202, true)
let remainingEventFiles = try FileManager.default.contentsOfDirectory(atPath: backlog.path)
check(remainingEventFiles.isEmpty, "stream did not ACK-drain backlog")
print("PASS M03 exact CoreEventRelay: 200 critical/mixed files, >5MiB payload, notification coalescing, fixed ACK window, failed retry, reset late ACK, ordered complete drain, ACK delete failure retry")
let localEntered = DispatchSemaphore(value: 0), localRelease = DispatchSemaphore(value: 0), localDone = DispatchSemaphore(value: 0)
relay.beforeLocalWrite = { localEntered.signal(); check(localRelease.wait(timeout: .now() + 10) == .success, "local event timeout") }
DispatchQueue.global().async { "local-critical".withCString { testEmitEvent($0) }; localDone.signal() }
check(localEntered.wait(timeout: .now() + 5) == .success, "real IOSCoreBridge local event missing")
var localReply = false
IOSCoreBridge.invokeMethod("request") { _ in localReply = true }
waitMain { localReply }
// Unchanged production Runner RPC still uses its main callback; only its
// event lane is isolated here. This is not M04 actual-operation admission.
localRelease.signal(); check(localDone.wait(timeout: .now() + 5) == .success, "local event producer stuck")
relay.flush(); check(relay.testInFlight() == 1, "local event not ACK-window delivered")
ack(203, true)
print("PASS M02 Runner real IOSCoreBridge: held local event writer leaves main/RPC responsive")
print("NATIVE SLICE ONLY: Go RPC M04/device footprint/real Provider Apple integration remain pending")
