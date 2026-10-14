// Exact production CoreEventRelay; only storage/bridge dependencies doubled.
import Foundation
import CoreFoundation
final class SharedStateStore {
  let root: URL
  let eventNotificationName = "test.ack.retry.\(UUID())"
  init(_ root: URL) { self.root = root }
  func eventQueueDirectory() -> URL? { root }
}
enum IOSCoreBridge {
  static func setEventListener(_ callback: @escaping (String?) -> Void) {}
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { print("FAIL ACK_RETRY: \(message)"); exit(1) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("001.json")
let payload = "{\"critical\":\"\(String(repeating: "界", count: 100000))\"}"
try payload.write(to: file, atomically: true, encoding: .utf8)
let lock = NSLock()
var replies: [(Bool) -> Void] = []
let store = SharedStateStore(root)
let relay = CoreEventRelay(sharedStateStore: store) { event, reply in
  check(event == payload, "complete event changed")
  lock.lock(); replies.append(reply); lock.unlock()
}
func sent() -> Int { lock.lock(); defer { lock.unlock() }; return replies.count }
func ack(_ index: Int, _ result: Bool) {
  lock.lock(); let reply = replies[index]; lock.unlock(); reply(result); relay.flush()
}
func storm() {
  for _ in 0..<10000 {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(store.eventNotificationName as CFString), nil, nil, true)
  }
  relay.flush()
}
#if ACK_RETRY_BASELINE || ACK_RETRY_AUTOMATIC
// Immutable candidate must reach this actual behavior assertion, not a compile error.
relay.start(); relay.flush(); ack(0, false)
let deadline = Date().addingTimeInterval(3)
while sent() < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01); relay.flush() }
check(sent() == 2, "ACK=false never automatically recovered")
var failDeleteOnce = true
relay.beforeDelete = {
  if failDeleteOnce { failDeleteOnce = false; throw NSError(domain: "delete-once", code: 1) }
}
ack(1, true)
let deleteDeadline = Date().addingTimeInterval(3)
while FileManager.default.fileExists(atPath: file.path) && Date() < deleteDeadline {
  Thread.sleep(forTimeInterval: 0.01); relay.flush()
}
check(!FileManager.default.fileExists(atPath: file.path) && sent() == 2, "delete never automatically recovered without redelivery")
print("PASS ACK_RETRY real production Swift: real Dispatch automatic ACK/delete retry without drain/init")
#else
var jobs: [DispatchWorkItem] = [], delays: [Double] = []
relay.scheduleTestRetry = { delay, item in jobs.append(item); delays.append(delay) }
func fire() { relay.testFireRetry(); relay.flush() }
relay.start(); relay.flush(); check(sent() == 1, "initial delivery")
storm(); check(sent() == 1 && jobs.isEmpty, "hung ACK retried concurrently")
ack(0, false)
storm(); check(jobs.count == 1 && relay.testRetryPending(), "storm did not coalesce retry")
fire(); check(sent() == 2, "ACK=false automatic recovery without drain/init")
relay.beforeDelete = { throw NSError(domain: "delete-once", code: 1) }
ack(1, true); check(relay.testRetryPending(), "delete failure no retry")
let count = jobs.count
ack(1, false); ack(1, true)
check(jobs.count == count && sent() == 2, "duplicate ACK changed delete authority")
storm(); check(jobs.count == count && sent() == 2, "ACKed event resent during delete retry")
relay.beforeDelete = nil
fire(); check(!FileManager.default.fileExists(atPath: file.path) && sent() == 2, "delete retry resent or lost ACK authority")
check(relay.testRetryAttempt() == 0, "success did not clear backoff")
// Read failure, without admitting a payload or requiring another notification.
try payload.write(to: file, atomically: true, encoding: .utf8)
relay.beforeRead = { throw NSError(domain: "read", code: 1) }
relay.drainEventQueue(); relay.flush()
check(sent() == 2 && relay.testRetryPending(), "read fault no bounded retry")
relay.beforeRead = nil; fire(); check(sent() == 3, "read did not automatically recover")
// Permanent failures grow to a finite cap; one scheduled item, never a spin.
ack(2, false)
for _ in 0..<12 { fire(); ack(sent() - 1, false) }
check(delays.allSatisfy { $0 >= 0.25 && $0 <= 8 } && delays.last == 8, "backoff not bounded")
let staleReset = jobs.last!
relay.reset(); relay.flush()
check(staleReset.isCancelled && !relay.testRetryPending(), "reset did not cancel retry owner")
relay.testPerformStale(staleReset); check(sent() == 15, "late reset retry admitted new delivery")
relay.drainEventQueue(); relay.flush(); check(sent() == 16, "new generation did not resume")
// A hung ACK across reset/stop still owns the physical Flutter slot.
relay.reset(); relay.flush(); relay.drainEventQueue(); relay.flush()
check(sent() == 16, "reset freed hung ACK slot")
try FileManager.default.removeItem(at: file)
try payload.write(to: file, atomically: true, encoding: .utf8)
ack(15, true); check(sent() == 17 && FileManager.default.fileExists(atPath: file.path), "old ACK deleted new-generation file")
ack(16, false)
let staleStop = jobs.last!
relay.stop(); relay.flush()
check(staleStop.isCancelled && !relay.testRetryPending(), "stop did not cancel retry owner")
relay.testPerformStale(staleStop); storm(); relay.drainEventQueue(); relay.flush()
check(sent() == 17 && FileManager.default.fileExists(atPath: file.path), "stopped owner retried/deleted")
relay.start(); relay.flush(); check(sent() == 18, "restart did not resume")
relay.stop(); relay.flush(); relay.start(); relay.flush()
check(sent() == 18, "stop/start freed hung ACK slot")
ack(17, true); check(sent() == 19 && FileManager.default.fileExists(atPath: file.path), "late stopped ACK deleted replacement")
ack(18, true); check(!FileManager.default.fileExists(atPath: file.path), "final ACK did not drain")
relay.stop(); relay.flush()
print("PASS ACK_RETRY real production Swift: auto ACK/delete/read recovery; coalesced bounded backoff; reset/stop ownership; hung ACK; complete event")
#endif
