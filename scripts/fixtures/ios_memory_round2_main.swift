// Actual production Swift + Foundation harness. macOS required (Darwin/os/ObjC).
import Foundation
import CoreFoundation

struct PacketTunnelEnvironment {
  static let appGroupIdentifier = "test.memory"
  static let extensionBundleIdentifier = "test.memory"
  static let eventNotificationName = "test.memory.event"
}
enum SwitchDiagnostics { static let processID = "test-owner" }
final class PacketTunnelSharedStateStore {
  let root: URL
  init(_ root: URL) { self.root = root }
  func appGroupDirectory() -> URL? { root }
}
enum NECoreBridge {
  static var listener: ((Data?) -> Void)?
  static func releaseMemory() {}
  static func setEventListener(_ callback: ((Data?) -> Void)?) { listener = callback }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { fatalError(message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let log = NativeDiagnosticLog.shared
let logURL = root.appendingPathComponent("diagnostic.log")
let enteredWrite = DispatchSemaphore(value: 0)
let releaseWrite = DispatchSemaphore(value: 0)
let writeLock = NSLock()
var firstWrite = true
log.setTestURL(logURL, beforeWrite: {
  writeLock.lock()
  let hold = firstWrite
  firstWrite = false
  writeLock.unlock()
  if hold {
    enteredWrite.signal()
    check(releaseWrite.wait(timeout: .now() + 10) == .success, "write gate timeout")
  }
})
log.append("first", discardable: true)
check(enteredWrite.wait(timeout: .now() + 5) == .success, "writer did not enter")
DispatchQueue.concurrentPerform(iterations: 2000) { _ in
  log.append(String(repeating: "🚀", count: 9000), discardable: true)
}
let pending = log.testPending()
check(pending.jobs <= NativeDiagnosticLog.maxPendingJobs, "unbounded jobs")
check(pending.bytes <= NativeDiagnosticLog.maxPendingBytes, "unbounded bytes")
check(pending.dropped > 0, "flood was not admission-bounded")
releaseWrite.signal()
log.flush()
check(log.testPending().jobs == 0 && log.testPending().bytes == 0, "pending counters leaked")
log.setTestURL(logURL)
log.append("critical-after-flood")
log.flush()
let flood = try Data(contentsOf: logURL)
check(String(decoding: flood, as: UTF8.self).contains("critical-after-flood"), "critical marker dropped")
for row in flood.split(separator: 0x0A) {
  check(row.count <= NativeDiagnosticLog.maxLineBytes, "line cap exceeded")
  check(String(data: Data(row), encoding: .utf8) != nil, "UTF8 split corrupt")
}
// A sparse inherited 64MiB file: production must only stream the newest window.
let sparse = try FileHandle(forWritingTo: logURL)
try sparse.truncate(atOffset: 64 * 1024 * 1024)
try sparse.seek(toOffset: 64 * 1024 * 1024 - 80)
try sparse.write(contentsOf: Data("\nretained-tail-marker\n".utf8))
try sparse.close()
log.append("after-rotation")
log.flush()
let rotated = try Data(contentsOf: logURL)
check(rotated.count <= 4 * 1024 * 1024, "rotation budget exceeded")
check(String(decoding: rotated, as: UTF8.self).contains("retained-tail-marker"), "tail was lost")
print("PASS diagnostics: pre-dispatch job/byte budget, line UTF8 cap, critical delivery, 64MiB streaming rotation")

// Native reclaim is blocked INSIDE the production tick. stop must not return
// until that old worker exits. It must not release a new owner's core early.
let enteredReclaim = DispatchSemaphore(value: 0)
let releaseReclaim = DispatchSemaphore(value: 0)
let stopped = DispatchSemaphore(value: 0)
let sampleLock = NSLock()
var footprint = 0
var reclaims = 0
let heartbeat = NativeResourceHeartbeat(reclaim: {
  sampleLock.lock(); reclaims += 1; sampleLock.unlock()
  enteredReclaim.signal()
  check(releaseReclaim.wait(timeout: .now() + 10) == .success, "reclaim gate timeout")
}, sample: {
  sampleLock.lock(); defer { sampleLock.unlock() }
  return (footprint, footprint, footprint)
})
heartbeat.start()
let oldOwner = heartbeat.testOwner()
sampleLock.lock(); footprint = 100; sampleLock.unlock()
DispatchQueue.global().async { heartbeat.testTick(owner: oldOwner) }
check(enteredReclaim.wait(timeout: .now() + 5) == .success, "reclaim did not enter")
DispatchQueue.global().async { heartbeat.stop(); stopped.signal() }
check(stopped.wait(timeout: .now() + 0.1) == .timedOut, "stop returned while old reclaim still running")
sampleLock.lock(); footprint = 0; sampleLock.unlock()
releaseReclaim.signal()
check(stopped.wait(timeout: .now() + 5) == .success, "stop did not drain worker")
heartbeat.start()
heartbeat.testTick(owner: oldOwner)
heartbeat.stop()
check(reclaims == 1, "stale handler reclaimed newer core")
DispatchQueue.concurrentPerform(iterations: 100) { index in
  if index % 2 == 0 { heartbeat.start() } else { heartbeat.stop() }
}
heartbeat.stop()
print("PASS heartbeat: blocked reclaim drain, late old-owner suppression, concurrent start/stop")

let events = NECoreEventQueue(sharedStateStore: PacketTunnelSharedStateStore(root))
func message(_ types: [String], bytes: Int = 1) -> Data {
  return try! JSONSerialization.data(withJSONObject: ["method": "message", "arguments": types.map { ["type": $0, "data": String(repeating: "x", count: bytes)] }])
}
check(NECoreEventQueue.isDiscardable(message(["log", "dns", "request"])), "bulk contract lost")
for critical in ["delay", "loaded", "geoUpdate", "unknown"] {
  check(!NECoreEventQueue.isDiscardable(message(["log", critical])), "mixed critical batch declared lossy")
}
check(!NECoreEventQueue.isDiscardable(Data("configuration-reply".utf8)), "unknown/config reply lossy")
events.start()
let oldListener = NECoreBridge.listener!
for index in 0..<30 { oldListener(message(["delay"], bytes: index + 1)) }
for _ in 0..<100 { oldListener(message(["log"])) }
let eventDir = root.appendingPathComponent("core-events")
func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: eventDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }) ?? [] }
check(files().filter { !$0.lastPathComponent.hasSuffix(".lossy.json") }.count == 30, "critical ack/file was pruned")
check(files().filter { $0.lastPathComponent.hasSuffix(".lossy.json") }.count <= 10, "lossy file cap exceeded")
// Preserve a complete multi-MiB payload; no invented 4MiB request/event limit.
let full = message(["loaded"], bytes: 5 * 1024 * 1024)
oldListener(full)
let fullPreserved = try files().contains { try Data(contentsOf: $0) == full }
check(fullPreserved, "large complete event was truncated/dropped")
events.stop()
let count = files().count
oldListener(message(["delay"]))
events.start()
oldListener(message(["delay"]))
check(files().count == count, "late event crossed stop/restart")
events.stop()
print("PASS events: synchronous bounded admission, critical/mixed retention, lossy prune, full >4MiB event, old generation")
print("NOTE: critical durable backlog is intentionally not capped without consumer ACK; footprint/device limit NOT established")
