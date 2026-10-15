// Actual controller/bridge/manager/coordinator/router/server plus BOTH real
// receipt stores. No fake receipt array in this native gate.
import Foundation
import Darwin
let caseName = CommandLine.arguments[1]
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
  if !ok() { print("FAIL NATIVE \(caseName): \(message)"); exit(1) }
}
func pause(_ ns: UInt64 = 100_000_000) async { try? await Task.sleep(nanoseconds: ns) }
func wait(_ condition: () -> Bool) async {
  let end = Date().addingTimeInterval(3)
  while !condition() && Date() < end { await pause(10_000_000) }
  check(condition(), "observable condition timed out")
}
let success = Data(#"{"result":"","error":null}"#.utf8)
let setup = Data(#"{"method":"setupConfig","id":"logical"}"#.utf8)
let read = Data(#"{"method":"getProxies","id":"read"}"#.utf8)
let mutation = Data(#"{"method":"changeProxy","id":"mutation"}"#.utf8)
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
let req = fixtureRoot.appendingPathComponent("core-rpc/req")
let resp = fixtureRoot.appendingPathComponent("core-rpc/resp")
try FileManager.default.createDirectory(at: req, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resp, withIntermediateDirectories: true)
let runnerStore = SharedStateStore()
let neStore = PacketTunnelSharedStateStore()
let callsLock = NSLock()
var heldCalls: [(Data?) -> Void] = []
func count() -> Int { callsLock.lock(); defer { callsLock.unlock() }; return heldCalls.count }
func respond(_ i: Int) { callsLock.lock(); let cb = heldCalls[i]; callsLock.unlock(); cb(success) }
let server = PacketTunnelCommandServer(sharedStateStore: neStore) { _, cb in
  callsLock.lock(); heldCalls.append(cb); callsLock.unlock()
}
Task { @MainActor in
  await ProviderMessageBridge.setTestRoot(fixtureRoot)
  let manager = NETunnelProviderManager()
  let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.attempt.NECore"
  manager.protocolConfiguration = proto
  NETunnelProviderManager.managers = [manager]
  let controller = TunnelController(sharedStateStore: runnerStore, onTunnelStateChanged: { _ in }, onConnectionStateChanged: { _ in }, onExternalStart: {}, onExternalStop: {})
  let attempt = UUID()
  check(RPCSession(version: RPCWire.version, attempt: attempt, ready: true).publish(to: fixtureRoot), "publish failed")
  if caseName == "receipt-codable-owner" {
    let owner = RPCOwner(attempt: attempt, generation: UInt64.max, nonce: UUID())
    neStore.markConfigurationRequestApplied("logical", owner: owner)
    check(runnerStore.isConfigurationRequestApplied("logical", owner: owner), "real defaults/Codable max UInt64 roundtrip failed")
    check(!runnerStore.isConfigurationRequestApplied("other", owner: owner), "wrong logical ID accepted")
    for other in [RPCOwner(attempt: UUID(), generation: owner.generation, nonce: owner.nonce), RPCOwner(attempt: attempt, generation: 0, nonce: owner.nonce), RPCOwner(attempt: attempt, generation: owner.generation, nonce: UUID())] {
      check(!runnerStore.isConfigurationRequestApplied("logical", owner: other), "wrong owner accepted")
    }
    let defaults = UserDefaults(suiteName: runnerStore.appGroupIdentifier)!
    defaults.set(try! JSONEncoder().encode(RPCAppliedReceipt(version: 999, owner: owner, requestID: "logical")), forKey: "appliedConfigurationRequest")
    check(!runnerStore.isConfigurationRequestApplied("logical", owner: owner), "unknown receipt version accepted")
    defaults.set("logical", forKey: "appliedConfigurationRequest")
    check(!runnerStore.isConfigurationRequestApplied("logical", owner: owner), "legacy receipt accepted")
    neStore.markConfigurationRequestApplied("logical", owner: owner)
    RPCSession(version: RPCWire.version, attempt: UUID(), ready: true).publish(to: fixtureRoot)
    check(!runnerStore.isConfigurationRequestApplied("logical", owner: owner), "old attempt receipt accepted")
  } else if caseName == "manager-held-cancel" {
    NETunnelProviderManager.holdLoads = true
    let store = TunnelManagerStore(sharedStateStore: runnerStore, networkExtensionIdentifier: "test.attempt.NECore", localizedDescription: "test")
    var done = false
    let task = Task { @MainActor in
      do { _ = try await store.loadManager(createIfNeeded: false); check(false, "cancel returned manager") }
      catch is CancellationError { done = true }
      catch { check(false, "cancel wrong error") }
    }
    await wait { NETunnelProviderManager.heldLoad != nil }
    let start = Date(); task.cancel(); await wait { done }
    check(Date().timeIntervalSince(start) < 0.5, "cancellation waited for 5s system callback")
    NETunnelProviderManager.heldLoad?([manager], nil); await pause()
  } else if caseName == "absolute-deadline" {
    NETunnelProviderManager.holdLoads = true
    var done = false
    let start = Date()
    Task { @MainActor in
      do { _ = try await controller.testSendAttempt(mutation, deadline: start.addingTimeInterval(0.2)); check(false, "expired manager returned") }
      catch { done = true }
    }
    await wait { done }
    check(Date().timeIntervalSince(start) < 0.6, "manager extended absolute budget")
    NETunnelProviderManager.heldLoad?([manager], nil); await pause()
    check(((try? FileManager.default.contentsOfDirectory(atPath: req.path)) ?? []).isEmpty, "expired request enqueued")
    let bridge = ProviderMessageBridge(appGroupIdentifier: runnerStore.appGroupIdentifier, commandNotificationName: "test.command")
    do { _ = try await bridge.send(mutation, deadline: start, owner: RPCOwner(attempt: attempt, generation: 0, nonce: UUID()), epoch: RPCClientEpoch(), clientEpoch: 0); check(false, "actor entry renewed deadline") } catch {}
  } else if caseName == "wrong-reply-owner" || caseName == "ack-lost-reply" {
    let bridge = ProviderMessageBridge(appGroupIdentifier: runnerStore.appGroupIdentifier, commandNotificationName: "test.command")
    let owner = RPCOwner(attempt: attempt, generation: UInt64.max, nonce: UUID())
    var done = false
    Task {
      do {
        let result = try await bridge.send(caseName == "ack-lost-reply" ? setup : mutation, deadline: Date().addingTimeInterval(2), owner: owner, epoch: RPCClientEpoch(), clientEpoch: 0)
        check(result.contains("result"), "success payload missing"); done = true
      } catch { check(false, "valid ACK/reply rejected") }
    }
    var requestFile: URL?
    await wait { requestFile = (try? FileManager.default.contentsOfDirectory(at: req, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "req" }; return requestFile != nil }
    let responseFile = resp.appendingPathComponent(requestFile!.deletingPathExtension().lastPathComponent + ".resp")
    if caseName == "wrong-reply-owner" {
      let wrong = RPCOwner(attempt: attempt, generation: owner.generation, nonce: UUID())
      try! JSONEncoder().encode(RPCReply(version: RPCWire.version, owner: wrong, data: success)).write(to: responseFile)
      await pause(250_000_000); check(!done, "wrong reply owner accepted")
      try! JSONEncoder().encode(RPCReply(version: RPCWire.version, owner: owner, data: success)).write(to: responseFile, options: .atomic)
    } else {
      neStore.markConfigurationRequestApplied("logical", owner: RPCOwner(attempt: attempt, generation: owner.generation, nonce: UUID()))
      await pause(200_000_000); check(!done, "wrong receipt nonce accepted")
      // No reply file: authoritative real receipt must finish within budget.
      neStore.markConfigurationRequestApplied("logical", owner: owner)
    }
    await wait { done }
  } else if caseName == "cold-connecting-pending-ready" || caseName == "session-replace" {
    manager.connection.status = .connecting
    RPCSession(version: RPCWire.version, attempt: attempt, ready: false).publish(to: fixtureRoot)
    var done = false, stale = false
    Task { @MainActor in
      do { _ = try await controller.sendProviderMessage(setup); done = true }
      catch let e as ProviderMessageError { stale = e.code == "stale_profile"; done = true }
      catch { check(false, "cold setup wrong error") }
    }
    await pause(200_000_000); check(!done && count() == 0, "cold setup failed/admitted before ready")
    if caseName == "session-replace" {
      RPCSession(version: RPCWire.version, attempt: UUID(), ready: true).publish(to: fixtureRoot)
      await wait { done }; check(stale && count() == 0, "old cold setup crossed attempt")
    } else {
      check(server.start(attempt: attempt), "server ready failed")
      await wait { count() == 1 }; respond(0); await wait { done }; check(!stale, "same cold attempt rejected")
    }
  } else if caseName == "same-attempt-slot-read" {
    check(server.start(attempt: attempt), "server failed")
    var tasks: [Task<Void, Never>] = []
    for _ in 0..<7 { tasks.append(Task { @MainActor in _ = try? await controller.sendProviderMessage(mutation) }) }
    await wait { count() == 7 }
    var oldDone = false, stale = false
    let queued = Task { @MainActor in
      do { _ = try await controller.sendProviderMessage(read) }
      catch let e as ProviderMessageError { stale = e.code == "stale_profile" }
      catch {}
      oldDone = true
    }
    await pause(); let generation = controller.beginConfigurationApply()
    controller.finishConfigurationApply(generation: generation, success: true)
    respond(0); await wait { oldDone }
    check(stale && count() == 7, "queued old read masqueraded as new read in same attempt")
    queued.cancel(); tasks.forEach { $0.cancel() }
  } else if caseName == "foreign-obsolete-status" || caseName == "legal-disconnect-recovery" {
    _ = await controller.isCoreActive(); controller.startObserving(); await pause()
    let original = controller.captureProviderOwner()
    let generation = controller.beginConfigurationApply()
    if caseName == "foreign-obsolete-status" {
      let foreign = NETunnelProviderManager(); foreign.connection.status = .disconnected
      NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: foreign.connection)
      let obsolete = NETunnelProviderManager(); obsolete.protocolConfiguration = proto; obsolete.connection.status = .disconnected
      NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: obsolete.connection)
      await pause()
      check((try? controller.validateProviderOwner(original)) != nil, "foreign/obsolete notification invalidated epoch")
      do { _ = try await controller.sendProviderMessage(read); check(false, "foreign status opened gate") }
      catch let e as ProviderMessageError { check(e.code == "profile_switching", "wrong gate error") } catch { check(false, "wrong error") }
    } else {
      RPCSession(version: RPCWire.version, attempt: attempt, ready: false, retired: true).publish(to: fixtureRoot)
      manager.connection.status = .disconnected
      NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: manager.connection)
      await pause()
      RPCSession(version: RPCWire.version, attempt: UUID(), ready: true).publish(to: fixtureRoot)
      manager.connection.status = .connected
      check(server.start(attempt: RPCSession.read(from: fixtureRoot)!.attempt), "new session failed")
      var done = false
      Task { @MainActor in _ = try? await controller.sendProviderMessage(read); done = true }
      await wait { count() == 1 }; respond(0); await wait { done }
    }
    controller.finishConfigurationApply(generation: generation, success: false)
  } else if caseName == "router-old-app-phase" {
    let router = CoreMessageRouter(tunnelController: controller)
    router.updateTunnelState(.running)
    IOSCoreBridge.holdApp = true
    var done = false, result = ""
    Task { @MainActor in result = await router.invoke(setup); done = true }
    await wait { IOSCoreBridge.heldApp != nil }
    RPCSession(version: RPCWire.version, attempt: UUID(), ready: true).publish(to: fixtureRoot)
    IOSCoreBridge.holdApp = false; IOSCoreBridge.heldApp?(String(decoding: success, as: UTF8.self))
    await wait { done }
    check(result.contains("stale_profile") && count() == 0, "old app phase forwarded to new NE")
  } else { check(false, "unknown test case") }
  server.stop()
  UserDefaults(suiteName: runnerStore.appGroupIdentifier)?.removePersistentDomain(forName: runnerStore.appGroupIdentifier)
  try? FileManager.default.removeItem(at: fixtureRoot)
  print("PASS NATIVE \(caseName)"); exit(0)
}
RunLoop.main.run()
