// Dependency doubles only. Real controller/bridge/server methods are compiled.
import Foundation
import CoreFoundation
import Darwin

enum TunnelTarget { case running, stopped }
enum NEVPNStatus: Int { case invalid, disconnected, connecting, connected, reasserting, disconnecting
  var tunnelState: TunnelTarget? { self == .connected || self == .reasserting ? .running : .stopped }
  var isTerminal: Bool { self == .invalid || self == .disconnected }
}
final class NEVPNConnection: NSObject { var status = NEVPNStatus.connected }
final class NETunnelProviderManager { let connection = NEVPNConnection() }
extension Notification.Name { static let NEVPNStatusDidChange = Notification.Name("test.status") }
enum UIApplication {
  static let didBecomeActiveNotification = Notification.Name("test.active")
  static let didEnterBackgroundNotification = Notification.Name("test.background")
  static let willEnterForegroundNotification = Notification.Name("test.foreground")
}
struct ProviderMessageError: Error { let code: String; let message: String }
struct PacketTunnelEnvironment {
  static let extensionBundleIdentifier = "test.attempt.ne"
  static let commandNotificationName = "test.attempt.command"
}
enum SwitchDiagnostics {
  static func responseErrorType(_ data: Data?, method: String) -> String { "none" }
  static func responseErrorType(_ response: String, method: String) -> String { "none" }
  static func record(_ event: String, fields: [String: String] = [:]) {}
  static func requestID(_ data: Data) -> String { "test-logical-id" }
  static func method(_ data: Data) -> String {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["method"] as? String ?? "unknown"
  }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
final class SharedStateStore {
  let appGroupIdentifier = "test.attempt"
  func appGroupDirectory() -> URL? { root }
  func clearConfigurationRequestApplied() { clearReceipts() }
  func isConfigurationRequestApplied(_ id: String) -> Bool { false }
  func isConfigurationRequestApplied(_ id: String, owner: RPCOwner) -> Bool {
    receipts.contains { $0.owner == owner && $0.requestID == id }
  }
  func runTime() -> Int { 1 }
}
let receiptLock = NSLock()
private var receiptStorage: [RPCAppliedReceipt] = []
var receipts: [RPCAppliedReceipt] {
  get { receiptLock.lock(); defer { receiptLock.unlock() }; return receiptStorage }
  set { receiptLock.lock(); defer { receiptLock.unlock() }; receiptStorage = newValue }
}
func clearReceipts() { receiptLock.lock(); defer { receiptLock.unlock() }; receiptStorage.removeAll() }
func appendReceipt(_ receipt: RPCAppliedReceipt) { receiptLock.lock(); defer { receiptLock.unlock() }; receiptStorage.append(receipt) }
final class PacketTunnelSharedStateStore {
  func appGroupDirectory() -> URL? { root }
  func clearConfigurationRequestApplied() { clearReceipts() }
  func markConfigurationRequestApplied(_ id: String) { appendReceipt(RPCAppliedReceipt(version: 0, owner: RPCOwner(attempt: UUID(), generation: 0, nonce: UUID()), requestID: id)) }
  func markConfigurationRequestApplied(_ id: String, owner: RPCOwner) { appendReceipt(RPCAppliedReceipt(version: RPCWire.version, owner: owner, requestID: id)) }
}
@MainActor final class TunnelManagerStore {
  let manager = NETunnelProviderManager()
  init(sharedStateStore: SharedStateStore, networkExtensionIdentifier: String, localizedDescription: String) {}
  func loadManager(createIfNeeded: Bool, deadline: Date? = nil) async throws -> NETunnelProviderManager? { manager }
  func isManagedConnection(_ c: NEVPNConnection) -> Bool { c === manager.connection }
  func refreshLoadedManager() async throws {}
}
@MainActor final class TunnelCoordinator {
  init(managerStore: TunnelManagerStore, onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
       onConnectionStateChanged: @escaping (String) -> Void, onExternalStart: @escaping () -> Void,
       onExternalStop: @escaping () -> Void) {}
  func ownsStatusConnection(_ c: NEVPNConnection) -> Bool { true }
  func handleTunnelStatusNotification(_ n: Notification) {}
  func requestStatusRefresh(notifyExternal: Bool) {}
  func submitTunnelRequest(target: TunnelTarget) {}
  func publishConnectionState() {}
  func toggleTunnelRequest() {}
  func reloadOnDemandRules() async throws {}
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { print("FAIL ATTEMPT: \(message)"); exit(1) }
}
func wait(_ predicate: () -> Bool) async {
  let until = Date().addingTimeInterval(3)
  while !predicate() && Date() < until { try? await Task.sleep(nanoseconds: 10_000_000) }
  check(predicate(), "observable condition timed out")
}
let callLock = NSLock()
var callbacks: [(Data?) -> Void] = []
func count() -> Int { callLock.lock(); defer { callLock.unlock() }; return callbacks.count }
func respond(_ index: Int, _ data: Data?) {
  callLock.lock(); let callback = callbacks[index]; callLock.unlock(); callback(data)
}
let success = Data(#"{"result":"","error":null}"#.utf8)
let mutation = Data(#"{"method":"changeProxy","id":"same"}"#.utf8)
let setup = Data(#"{"method":"setupConfig","id":"same"}"#.utf8)
let read = Data(#"{"method":"getProxies","id":"read"}"#.utf8)
let server = PacketTunnelCommandServer(sharedStateStore: PacketTunnelSharedStateStore()) { _, callback in
  callLock.lock(); callbacks.append(callback); callLock.unlock()
}
let req = root.appendingPathComponent("core-rpc/req", isDirectory: true)
let resp = root.appendingPathComponent("core-rpc/resp", isDirectory: true)
try FileManager.default.createDirectory(at: req, withIntermediateDirectories: true)

Task { @MainActor in
  #if ATTEMPT_BASELINE
  // These are real legacy mailbox requests left unconsumed by a dead NE.
  for i in 0..<3 { try mutation.write(to: req.appendingPathComponent("old\(i).req")) }
  server.start()
  await wait { count() == 3 }
  check(count() == 0, "new NE executed 3 old mutations")
  #else
  await ProviderMessageBridge.setTestRoot(root)
  // Startup not-ready -> ready is one attempt, not a reason to reject legal work.
  let cold = UUID()
  check(RPCSession(version: RPCWire.version, attempt: cold, ready: false).publish(to: root), "startup publish failed")
  let coldEpoch = RPCClientEpoch()
  let coldBridge = ProviderMessageBridge(appGroupIdentifier: "test.attempt", commandNotificationName: "test.attempt.command")
  var coldDone = false
  Task {
    do { _ = try await coldBridge.send(setup, deadline: Date().addingTimeInterval(120), owner: RPCOwner(attempt: cold, generation: 0, nonce: UUID()), epoch: coldEpoch, clientEpoch: 0); coldDone = true }
    catch { check(false, "same cold attempt rejected") }
  }
  try? await Task.sleep(nanoseconds: 100_000_000)
  check(count() == 0, "cold work executed before ready")
  check(server.start(attempt: cold), "cold ready publish failed")
  await wait { count() == 1 }; respond(0, success); await wait { coldDone }
  server.stop()
  callLock.lock(); callbacks.removeAll(); callLock.unlock(); clearReceipts()
  let old = UUID(), current = UUID()
  func write(_ id: String, _ attempt: UUID, data: Data = mutation, version: Int = RPCWire.version, deadline: Date = Date().addingTimeInterval(120)) throws {
    let request = RPCRequest(version: version, owner: RPCOwner(attempt: attempt, generation: 1, nonce: UUID()), deadline: deadline, data: data)
    try JSONEncoder().encode(request).write(to: req.appendingPathComponent("\(id).req"))
  }
  for i in 0..<3 { try write("old\(i)", old) }
  try mutation.write(to: req.appendingPathComponent("legacy.req"))
  try write("future", current, version: 999)
  try write("expired", current, deadline: Date().addingTimeInterval(-1))
  check(server.start(attempt: current), "server publish failed")
  await wait { ((try? FileManager.default.contentsOfDirectory(atPath: req.path).count) ?? -1) == 0 }
  check(count() == 0, "new NE executed 3 old mutations")
  // Ready publication precedes admission; a same-attempt setup is not rejected.
  try write("setup", current, data: setup)
  await wait { count() == 1 }
  respond(0, success)
  await wait { FileManager.default.fileExists(atPath: resp.appendingPathComponent("setup.resp").path) }
  check(receipts.count == 1 && receipts[0].owner.attempt == current, "valid setup missing owned receipt")
  try write("held", current, data: setup)
  await wait { count() == 2 }
  server.stop()
  check(RPCSession.read(from: root) == nil, "stop left ready owner")
  let next = UUID()
  check(server.start(attempt: next), "new server publish failed")
  respond(1, success)
  try? await Task.sleep(nanoseconds: 250_000_000)
  check(receipts.count == 0, "old callback dirtied new receipt") // held cleared receipt at admission
  check(!FileManager.default.fileExists(atPath: resp.appendingPathComponent("held.resp").path), "old callback wrote new response")

  let controller = TunnelController(sharedStateStore: SharedStateStore(), onTunnelStateChanged: { _ in }, onConnectionStateChanged: { _ in }, onExternalStart: {}, onExternalStop: {})
  let generationA = controller.beginConfigurationApply()
  var oldDone = false, oldError = ""
  let oldTask = Task { @MainActor in
    do { _ = try await controller.sendProviderMessage(setup); oldError = "success" }
    catch let error as ProviderMessageError { oldError = error.code }
    catch { oldError = "other" }
    oldDone = true
  }
  await wait { count() == 3 }
  controller.stop() // must terminate await without real Core callback
  await wait { oldDone }
  check(oldError == "stale_profile", "old setup did not retire promptly")
  let generationB = controller.beginConfigurationApply()
  controller.finishConfigurationApply(generation: generationA, success: true)
  do { _ = try await controller.sendProviderMessage(read); check(false, "old finish released new gate") }
  catch let e as ProviderMessageError { check(e.code == "profile_switching", "new gate not held") }
  catch { check(false, "new gate wrong error") }
  controller.finishConfigurationApply(generation: generationB, success: true)
  var readDone = false
  Task { @MainActor in
    do { _ = try await controller.sendProviderMessage(read); readDone = true }
    catch { check(false, "read after retirement failed") }
  }
  await wait { count() == 4 }; respond(3, success); await wait { readDone }
  _ = oldTask

  // Identity change without an observed disconnected notification still retires
  // the old await and its gate through the bridge's session check.
  let generationC = controller.beginConfigurationApply()
  var restartDone = false
  Task { @MainActor in
    do { _ = try await controller.sendProviderMessage(setup); check(false, "cross-attempt response accepted") }
    catch { restartDone = true }
  }
  await wait { count() == 5 }
  server.stop(); check(server.start(attempt: UUID()), "restart publish failed")
  await wait { restartDone }
  controller.finishConfigurationApply(generation: generationC, success: false)
  respond(4, success)
  // Cancellation must throw, not spin through try? sleep to 120 seconds.
  let epoch = RPCClientEpoch()
  let bridge = ProviderMessageBridge(appGroupIdentifier: "test.attempt", commandNotificationName: "test.attempt.command")
  let session = RPCSession.read(from: root)!
  var cancelled = false
  let task = Task {
    do { _ = try await bridge.send(setup, deadline: Date().addingTimeInterval(120), owner: RPCOwner(attempt: session.attempt, generation: 0, nonce: UUID()), epoch: epoch, clientEpoch: 0) }
    catch is CancellationError { cancelled = true }
    catch { check(false, "cancellation wrong error") }
  }
  await wait { count() == 6 }; task.cancel(); await wait { cancelled }
  // Preserve mailbox nil response as an error payload, not mutation replay.
  var nilReadDone = false
  Task { @MainActor in
    do {
      let response = try await controller.sendProviderMessage(read)
      check(response.contains("empty_response"), "mailbox nil response contract changed")
      nilReadDone = true
    } catch { check(false, "nil mailbox response unexpectedly threw") }
  }
  await wait { count() == 7 }; respond(6, nil)
  await wait { nilReadDone }
  check(count() == 7, "nil mailbox response unexpectedly replayed")
  server.stop()
  print("PASS ATTEMPT real Swift: old queued writes rejected; version/expiry; same-attempt setup; strict receipt owner; late callback; stopped/restarted await retirement; old gate finish; cancellation")
  #endif
  try? FileManager.default.removeItem(at: root)
  exit(0)
}
RunLoop.main.run()
