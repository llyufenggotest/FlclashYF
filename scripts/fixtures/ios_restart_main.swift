// Real production TunnelCoordinator + TunnelTypes, unchanged method bodies.
// Doubles only the NetworkExtension / manager preference boundary.
// Same fixture bytes and case assertions for immutable RED and candidate GREEN.
import Foundation
import Darwin

enum NEVPNStatus: Int { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
final class NEVPNConnection: NSObject {
  var status = NEVPNStatus.connected
  var starts = 0, stops = 0
  var holdStop = false, ignoreStop = false
  var preparedOptions = "initial"
  var startedOptions: [String] = []
  func startVPNTunnel() throws {
    starts += 1; startedOptions.append(preparedOptions); status = .connecting
  }
  func stopVPNTunnel() {
    stops += 1
    if !ignoreStop { status = holdStop ? .disconnecting : .disconnected }
  }
}
final class NETunnelProviderManager {
  let connection = NEVPNConnection()
  var isEnabled = true
  var holdSave = false
  var pendingSaves: [(Error?) -> Void] = []
  func saveToPreferences(completionHandler: @escaping (Error?) -> Void) {
    if holdSave { pendingSaves.append(completionHandler) } else { completionHandler(nil) }
  }
  func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}
@MainActor final class TunnelManagerStore {
  let manager: NETunnelProviderManager
  var options = "initial"
  var loads = 0
  var holdLoad = false
  var pendingLoad: CheckedContinuation<NETunnelProviderManager?, Error>?
  init(_ manager: NETunnelProviderManager) { self.manager = manager }
  func loadManager(createIfNeeded: Bool = true) async throws -> NETunnelProviderManager? {
    loads += 1
    if holdLoad {
      return try await withCheckedThrowingContinuation { pendingLoad = $0 }
    }
    return manager
  }
  func isManagedConnection(_ c: NEVPNConnection) -> Bool { c === manager.connection }
  func isCachedConnection(_ c: NEVPNConnection) -> Bool { c === manager.connection }
  func invalidateCachedManager(forPreferenceError: Error) -> Bool { false }
  func applyNetworkExtensionOptions(to manager: NETunnelProviderManager, enableOnDemand: Bool) {
    manager.connection.preparedOptions = options
  }
}
let caseName = CommandLine.arguments[1]
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
  if !ok() { print("FAIL RESTART \(caseName): \(message)"); exit(1) }
}
Task { @MainActor in
  let m = NETunnelProviderManager()
  let store = TunnelManagerStore(m)
  var connectionStates: [String] = []
  var tunnelStates: [TunnelTarget] = []
  var externalStarts = 0
  let coordinator = TunnelCoordinator(managerStore: store,
    onTunnelStateChanged: { tunnelStates.append($0) },
    onConnectionStateChanged: { connectionStates.append($0) },
    onExternalStart: { externalStarts += 1 }, onExternalStop: {})
  @MainActor func pause(_ seconds: Double = 0.08) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
  @MainActor func until(_ message: String, _ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !predicate() && Date() < deadline { await pause(0.01) }
    check(predicate(), message)
  }
  @MainActor func post(_ c: NEVPNConnection) {
    coordinator.handleTunnelStatusNotification(Notification(name: Notification.Name("test.status"), object: c))
  }
  @MainActor func connected() async {
    m.connection.status = .connected; post(m.connection)
    await until("start did not settle") { connectionStates.last == "connected" }
    await pause()
  }
  @MainActor func restart() {
    coordinator.submitTunnelRequest(target: .stopped)
    coordinator.submitTunnelRequest(target: .running)
  }
  if caseName == "coalesced-stop-start" {
    store.options = "new-options"
    coordinator.submitTunnelRequest(target: .stopped)
    coordinator.submitTunnelRequest(target: .stopped) // merge before dispatch
    coordinator.submitTunnelRequest(target: .running)
    coordinator.submitTunnelRequest(target: .running) // merge new running intent
    await until("restart must actually stop and start once") { m.connection.starts == 1 }
    check(m.connection.stops == 1, "missing stop before coalesced start")
    check(m.connection.startedOptions == ["new-options"], "new start options were not applied")
    await connected()
    coordinator.submitTunnelRequest(target: .running); await pause()
    check(m.connection.stops == 1 && m.connection.starts == 1, "debt leaked into later start")
  } else if caseName == "already-dispatched-stop" {
    m.connection.holdStop = true
    coordinator.submitTunnelRequest(target: .stopped)
    await until("original stop never dispatched") { m.connection.stops == 1 }
    coordinator.submitTunnelRequest(target: .running)
    await pause()
    check(m.connection.stops == 1 && m.connection.starts == 0, "already dispatched stop was duplicated or bypassed")
    m.connection.status = .disconnected; post(m.connection)
    await until("new request did not take over dispatched stop") { m.connection.starts == 1 }
    await connected()
    coordinator.submitTunnelRequest(target: .running); await pause()
    check(m.connection.stops == 1 && m.connection.starts == 1, "dispatched-stop debt survived completion")
  } else if caseName == "new-generation-options" {
    m.connection.holdStop = true
    store.options = "retired"
    restart()
    await until("missing restart barrier") { m.connection.stops == 1 }
    store.options = "newest"
    restart()
    await pause()
    check(m.connection.starts == 0 && m.connection.stops == 1, "retired generation crossed held stop")
    m.holdSave = true
    m.connection.status = .disconnected; post(m.connection)
    await until("new generation preference barrier missing") { m.pendingSaves.count == 1 }
    // Let the retired wait's original five-second deadline pass while the
    // newer request is still held. Its cancelled timer cannot finish the new one.
    await pause(5.3)
    check(m.connection.starts == 0 && connectionStates.last == "pending", "stale timeout retired new generation")
    m.holdSave = false
    let newSave = m.pendingSaves.removeFirst(); newSave(nil)
    await until("new generation did not start") { m.connection.starts == 1 }
    check(m.connection.startedOptions == ["newest"], "retired options replaced newest options")
    await connected()
  } else if caseName == "stale-completion" {
    store.holdLoad = true
    restart()
    await until("manager load barrier missing") { store.pendingLoad != nil }
    coordinator.submitTunnelRequest(target: .stopped)
    store.holdLoad = false
    let oldLoad = store.pendingLoad!; store.pendingLoad = nil
    oldLoad.resume(returning: m)
    await until("new stop was not dispatched") { m.connection.stops == 1 }
    post(m.connection)
    await until("new stop did not complete") { connectionStates.last == "disconnected" }
    check(m.connection.starts == 0 && m.connection.stops == 1, "stale load finished or launched retired start")
    store.options = "after-stale-load"
    coordinator.submitTunnelRequest(target: .running)
    await until("new start failed after stale load") { m.pendingSaves.count == 0 && m.connection.starts == 1 }
    await connected()
    // Hold a real preference callback, replace its request, then release it.
    m.connection.status = .disconnected; post(m.connection)
    m.holdSave = true
    coordinator.submitTunnelRequest(target: .running)
    await until("preference completion barrier missing") { m.pendingSaves.count == 1 }
    coordinator.submitTunnelRequest(target: .stopped)
    m.holdSave = false
    let staleSave = m.pendingSaves.removeFirst(); staleSave(nil)
    await until("third stop lost after stale preference completion") { connectionStates.last == "disconnected" }
    check(m.connection.starts == 1, "stale preference completion dispatched retired start")
    await pause()
    check(externalStarts == 1, "stale completion emitted external start")
  } else if caseName == "third-stop-and-unrelated-status" {
    m.connection.holdStop = true
    restart()
    await until("missing stop barrier") { m.connection.stops == 1 }
    let unrelated = NEVPNConnection(); unrelated.status = .disconnected
    check(!coordinator.ownsStatusConnection(unrelated), "foreign connection was accepted")
    post(unrelated); await pause()
    check(m.connection.starts == 0 && connectionStates.last == "pending", "foreign disconnect resumed owned wait")
    coordinator.submitTunnelRequest(target: .stopped)
    await pause()
    m.connection.status = .disconnected; post(m.connection)
    await until("third stop did not settle") { connectionStates.last == "disconnected" }
    check(m.connection.starts == 0 && externalStarts == 0, "retired restart crossed third stop")
    coordinator.submitTunnelRequest(target: .running)
    await until("fresh start missing after third stop") { m.connection.starts == 1 }
    await connected()
    check(m.connection.stops == 1, "cancelled wait leaked debt into new generation")
  } else if caseName == "restart-stop-timeout" {
    m.connection.ignoreStop = true
    restart()
    // Exercise the ORIGINAL production five-second DispatchWorkItem timeout.
    // No patched clock, reset deadline, synthetic wait result, or baseline flag.
    await pause(5.6)
    check(m.connection.stops == 1 && m.connection.starts == 0, "timeout retried or started without terminal stop")
    check(connectionStates.last != "connected", "restart reported connected from unchanged old tunnel after stop timeout")
    check(connectionStates.last == "disconnected", "failed restart remained pending")
    check(externalStarts == 0 && !tunnelStates.contains(.running), "failed restart emitted a success callback")
    let loads = store.loads
    await pause(0.2)
    check(store.loads == loads && m.connection.stops == 1, "timeout left an active request or stop loop")
    let unrelated = NEVPNConnection(); unrelated.status = .disconnected
    post(unrelated); post(m.connection)
    coordinator.requestStatusRefresh(notifyExternal: true)
    await pause()
    check(connectionStates.last == "disconnected" && externalStarts == 0, "unchanged or foreign status erased restart failure")
    // A real managed transition retires the failure latch, unlike a refresh.
    m.connection.status = .disconnected; post(m.connection)
    m.connection.status = .connected; post(m.connection)
    await pause()
    check(connectionStates.last == "connected" && externalStarts == 1, "real status transition could not recover failure state")
    // A genuinely new generation is permitted; old timeout cannot retire it.
    m.connection.ignoreStop = false
    restart()
    await until("new generation lost after timeout") { m.connection.starts == 1 }
    await connected()
    check(m.connection.stops == 2, "new generation did not obtain its own terminal stop")
  } else if caseName == "dispatched-stop-timeout" {
    m.connection.holdStop = true
    coordinator.submitTunnelRequest(target: .stopped)
    await until("original stop missing") { m.connection.stops == 1 }
    coordinator.submitTunnelRequest(target: .running)
    await pause(5.6)
    check(m.connection.starts == 0 && m.connection.stops == 1, "settle timeout repeated dispatched stop")
    check(connectionStates.last != "connected", "disconnecting timeout claimed connected")
    m.connection.status = .disconnected; post(m.connection)
    coordinator.submitTunnelRequest(target: .running)
    await until("new start blocked after dispatched-stop timeout") { m.connection.starts == 1 }
    await connected()
  } else if caseName == "no-debt-loop" {
    m.connection.status = .disconnected
    coordinator.submitTunnelRequest(target: .stopped)
    await until("already stopped request did not complete") { connectionStates.last == "disconnected" }
    coordinator.submitTunnelRequest(target: .running)
    await until("cold start missing") { m.connection.starts == 1 }
    await connected()
    for _ in 0..<3 { coordinator.submitTunnelRequest(target: .running); await pause() }
    check(m.connection.stops == 0 && m.connection.starts == 1, "terminal stop left restart debt")
  } else { check(false, "unknown case") }
  print("PASS RESTART \(caseName)"); exit(0)
}
RunLoop.main.run()
