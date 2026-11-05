// macOS harness: compiles the real cleanup, event queue and mailbox server.
// Only app-group, diagnostics and bridge dependencies are test doubles.
import Foundation
import CoreFoundation

struct PacketTunnelEnvironment {
  static let extensionBundleIdentifier = "test.necore.lifecycle"
  static let commandNotificationName = "test.necore.lifecycle.command"
  static let eventNotificationName = "test.necore.lifecycle.event"
}
final class PacketTunnelSharedStateStore {
  let root: URL
  private let lock = NSLock()
  private var applied: [String] = []
  init(_ root: URL) { self.root = root }
  func appGroupDirectory() -> URL? { root }
  func clearConfigurationRequestApplied() {}
  func markConfigurationRequestApplied(_ id: String, owner: RPCOwner) {
    lock.lock(); defer { lock.unlock() }; applied.append(id)
  }
  var appliedCount: Int {
    lock.lock(); defer { lock.unlock() }; return applied.count
  }
}
enum SwitchDiagnostics {
  static func responseErrorType(_ data: Data?, method: String) -> String { "none" }
  static func requestID(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }
  static func method(_ data: Data) -> String { "setupConfig" }
  static func record(_ phase: String, fields: [String: String]) {
    trace("rpc phase=\(phase) fields=\(fields.sorted { $0.key < $1.key })")
  }
}
enum NECoreBridge {
  private static let lock = NSLock()
  private static var callback: ((Data?) -> Void)?
  static func setEventListener(_ listener: ((Data?) -> Void)?) {
    lock.lock(); defer { lock.unlock() }; callback = listener
  }
  static func listener() -> ((Data?) -> Void)? {
    lock.lock(); defer { lock.unlock() }; return callback
  }
}
final class Calls {
  private let lock = NSLock()
  private var calls: [(Data?) -> Void] = []
  func add(_ callback: @escaping (Data?) -> Void) {
    lock.lock(); defer { lock.unlock() }; calls.append(callback)
  }
  var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
  func reply(_ index: Int, _ data: Data?) {
    lock.lock(); let callback = calls[index]; lock.unlock()
    trace("CALLBACK_REPLY index=\(index) bytes=\(data?.count ?? -1)")
    callback(data)
  }
}
func trace(_ message: String) {
  let line = "LIFECYCLE \(Date().timeIntervalSince1970) uptime=\(ProcessInfo.processInfo.systemUptime) \(message)\n"
  FileHandle.standardError.write(Data(line.utf8))
}
func check(_ value: @autoclosure () -> Bool, _ message: String,
           file: StaticString = #file, line: UInt = #line) {
  guard value() else {
    trace("FAIL file=\(file) line=\(line) \(message)")
    fatalError(message, file: file, line: line)
  }
}
func wait(_ stage: String, _ condition: () -> Bool,
          file: StaticString = #file, line: UInt = #line) {
  trace("WAIT_BEGIN stage=\(stage) file=\(file) line=\(line)")
  let until = Date().addingTimeInterval(5)
  while !condition() && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
  let satisfied = condition()
  if !satisfied { trace("WAIT_STATE stage=\(stage) \(mailboxSnapshot())") }
  check(satisfied, "condition did not become true stage=\(stage)", file: file, line: line)
  trace("WAIT_END stage=\(stage)")
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = PacketTunnelSharedStateStore(root)
let calls = Calls()
let server = PacketTunnelCommandServer(sharedStateStore: store, invoke: { _, completion in calls.add(completion) })
let req = root.appendingPathComponent("core-rpc/req")
let resp = root.appendingPathComponent("core-rpc/resp/reused.resp")
try FileManager.default.createDirectory(at: req, withIntermediateDirectories: true)
func mailboxSnapshot() -> String {
  let session = RPCSession.readPublished(from: root)
  let requestFile = req.appendingPathComponent("reused.req")
  let bytes = try? Data(contentsOf: requestFile)
  let decoded = bytes.flatMap { try? JSONDecoder().decode(RPCRequest.self, from: $0) }
  let files = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
  return "calls=\(calls.count) applied=\(store.appliedCount) session=\(String(describing: session)) request_bytes=\(bytes?.count ?? -1) request_owner=\(String(describing: decoded?.owner)) request_deadline=\(String(describing: decoded?.deadline)) files=\(files.sorted())"
}
trace("RUN os=\(ProcessInfo.processInfo.operatingSystemVersionString) root=\(root.path)")
func request() throws {
  let session = RPCSession.read(from: root)!
  let request = RPCRequest(version: RPCWire.version, owner: RPCOwner(attempt: session.attempt, generation: 0, nonce: UUID()), deadline: Date().addingTimeInterval(120), data: Data("request".utf8))
  let bytes = try JSONEncoder().encode(request)
  trace("REQUEST_BEGIN owner=\(request.owner) deadline=\(request.deadline.timeIntervalSince1970) bytes=\(bytes.count)")
  try bytes.write(to: req.appendingPathComponent("reused.req"))
  trace("REQUEST_PUBLISHED \(mailboxSnapshot())")
}
server.start(); try request(); wait("mailbox.initial.invoke") { calls.count == 1 }
server.stop(); server.start(); try request(); wait("mailbox.restart.invoke") { calls.count == 2 }
// A callback from before stop must not complete the reused filename or mark config.
calls.reply(0, Data(#"{"result":"","error":null}"#.utf8))
Thread.sleep(forTimeInterval: 0.3)
check(!FileManager.default.fileExists(atPath: resp.path), "old callback published reused response")
check(store.appliedCount == 0, "old callback marked config applied")
calls.reply(1, Data(#"{"result":"","error":null}"#.utf8))
wait("mailbox.current.response") { FileManager.default.fileExists(atPath: resp.path) }
check(store.appliedCount == 1, "current callback missing config marker")
calls.reply(1, Data("duplicate".utf8)); Thread.sleep(forTimeInterval: 0.3)
check(store.appliedCount == 1, "duplicate callback reapplied config")
let responseText = try String(contentsOf: resp, encoding: .utf8)
check(responseText != "duplicate", "duplicate overwrote response")
try FileManager.default.removeItem(at: resp)
try request(); wait("mailbox.long.invoke") { calls.count == 3 }
// Real elapsed time, not a mock model, exercises the recovered 30s regression.
Thread.sleep(forTimeInterval: 31)
check(!FileManager.default.fileExists(atPath: resp.path), "server manufactured an early timeout")
calls.reply(2, nil); wait("mailbox.nil.response") { FileManager.default.fileExists(atPath: resp.path) }
let nilReply = try JSONDecoder().decode(RPCReply.self, from: Data(contentsOf: resp))
let nilResult = try JSONSerialization.jsonObject(with: nilReply.data) as! [String: Any]
check((nilResult["error"] as? [String: Any])?["code"] as? String == "empty_response", "nil RPC contract changed")
server.stop()

let events = NECoreEventQueue(sharedStateStore: store)
let eventDirectory = root.appendingPathComponent("core-events")
func eventCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: eventDirectory.path).filter { $0.hasSuffix(".json") }.count) ?? 0 }
events.start(); let oldListener = NECoreBridge.listener()!
oldListener(Data("first".utf8)); wait("events.first.persist") { eventCount() == 1 }
events.stop(); events.markCoreResponsive(); oldListener(Data("stopped".utf8))
Thread.sleep(forTimeInterval: 0.1); check(eventCount() == 1, "stop was not terminal")
events.start(); oldListener(Data("old generation".utf8))
Thread.sleep(forTimeInterval: 0.1); check(eventCount() == 1, "old event crossed restart")
let listener = NECoreBridge.listener()!
let lossyEvent = Data(#"{"method":"message","arguments":[{"type":"log","data":"event"}]}"#.utf8)
DispatchQueue.concurrentPerform(iterations: 100) { _ in listener(lossyEvent) }
Thread.sleep(forTimeInterval: 0.5)
check(eventCount() <= 11, "lossy event queue cap lost under concurrency")
let count = eventCount(); events.markCoreResponsive(); listener(Data("responsive".utf8))
wait("events.responsive.persist") { eventCount() > count }; events.stop()

let lock = NSLock(); var cleanupCount = 0
let cleanup = PacketTunnelLifecycleCleanup(actions: [{ lock.lock(); cleanupCount += 1; lock.unlock() }])
DispatchQueue.concurrentPerform(iterations: 100) { _ in cleanup.cleanup() }
check(cleanupCount == 1, "cleanup ran more than once")
print("PASS: real mailbox stale/reused/duplicate/nil/31s callbacks, concurrent bounded events, terminal stop/restart, concurrent idempotent cleanup")
