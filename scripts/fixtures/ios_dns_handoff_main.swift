// Production router/controller/coordinator method bodies; only OS/Core ABI doubled.
import Foundation
import Darwin
let caseName = CommandLine.arguments[1]
let knownCases = ["suspend-barrier", "toggle-start", "superseded-start", "terminal-stop", "suspend-false",
  "active-config", "connecting-config", "stop-restore", "stop-failure", "stale-status",
  "late-resume", "offline-config", "resume-false", "envelopes",
  "reload-during-idle-suspend", "reload-during-idle-resume"]
if !knownCases.contains(caseName) { print("FAIL DNS unknown case"); exit(1) }
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
  if !ok() { print("FAIL DNS \(caseName): \(message)"); exit(1) }
}
Task { @MainActor in
  @MainActor func pause() async { try? await Task.sleep(nanoseconds:80_000_000) }
  @MainActor func until(_ message: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds:10_000_000) }
    check(condition(), message)
  }
  let manager = NETunnelProviderManager()
  let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.attempt.NECore"
  manager.protocolConfiguration = proto; manager.connection.status = .disconnected
  NETunnelProviderManager.managers = [manager]
  let shared = SharedStateStore()
  var reported: [TunnelTarget] = []
  var routerReference: CoreMessageRouter?
  let controller = TunnelController(sharedStateStore:shared, onTunnelStateChanged:{ reported.append($0); routerReference?.updateTunnelState($0) },
    onConnectionStateChanged:{ _ in }, onExternalStart:{}, onExternalStop:{})
  let router = CoreMessageRouter(tunnelController:controller)
  routerReference = router
  try! FileManager.default.createDirectory(at:fixtureRoot,withIntermediateDirectories:true)
  await ProviderMessageBridge.setTestRoot(fixtureRoot)
  let server = PacketTunnelCommandServer(sharedStateStore:PacketTunnelSharedStateStore()) { _, completion in
    check(IOSCoreBridge.calls.contains("suspendDnsListener"), "NE apply before App quiesced")
    completion(Data(#"{"result":"","error":null}"#.utf8))
  }
  check(server.start(attempt:UUID()), "test server could not publish")
  controller.startObserving(); await pause()
  @MainActor func post(_ status: NEVPNStatus) async {
    manager.connection.status = status
    NotificationCenter.default.post(name:.NEVPNStatusDidChange,object:manager.connection)
    await pause()
  }
  @MainActor func stop() async {
    controller.stop(); await pause(); await post(.disconnected)
  }
  let config = Data(#"{"method":"setupConfig","arguments":{},"id":"dns"}"#.utf8)
  if caseName == "reload-during-idle-suspend" || caseName == "reload-during-idle-resume" {
    let resuming = caseName == "reload-during-idle-resume"
    if resuming {
      // Acquire suspend debt through idle reconciliation, not a start request.
      await post(.connected)
      check(IOSCoreBridge.calls.contains("suspendDnsListener"), "initial idle suspend missing")
      IOSCoreBridge.holdResume = true
      await post(.disconnected)
      await until("idle resume not held") { IOSCoreBridge.heldResume != nil }
    } else {
      IOSCoreBridge.holdSuspend = true
      await post(.connected)
      await until("idle suspend not held") { IOSCoreBridge.heldSuspend != nil }
    }
    let savesBefore = manager.preferenceSaves
    let startsBefore = manager.connection.starts, stopsBefore = manager.connection.stops
    let statusBefore = manager.connection.status
    var entered = 0, completed = 0, failures = 0
    // Each task reaches the actual continuation queue while the ABI is held.
    for _ in 0..<3 {
      Task { @MainActor in
        entered += 1
        do { try await controller.reloadOnDemandRules() } catch { failures += 1 }
        completed += 1
      }
    }
    await until("reload tasks did not enter") { entered == 3 }
    await pause()
    check(completed == 0, "reload bypassed held idle operation")
    check(manager.preferenceSaves == savesBefore, "reload executed before idle release")
    let release = resuming ? IOSCoreBridge.heldResume! : IOSCoreBridge.heldSuspend!
    IOSCoreBridge.heldResume = nil; IOSCoreBridge.heldSuspend = nil
    IOSCoreBridge.holdResume = false; IOSCoreBridge.holdSuspend = false
    release(#"{"result":true,"error":null}"#)
    // No status notifications, start/stop, or further reloads may rescue waiters.
    await until("configuration waiters stranded by idle DNS await") { completed == 3 }
    check(failures == 0, "queued reload failed")
    check(manager.preferenceSaves == savesBefore + 1, "queued reload batch lost or duplicated")
    check(manager.connection.starts == startsBefore && manager.connection.stops == stopsBefore,
      "reload changed tunnel request ownership")
    check(manager.connection.status == statusBefore, "reload changed lifecycle status")
  } else if caseName == "envelopes" {
    // Every false/malformed ABI envelope must prevent a real start.
    let bad: [String?] = [nil, #"{"result":false}"#, #"{"result":true,"error":{"code":"failed"}}"#,
      #"{"result":1}"#, #"{"result":"true"}"#, #"{}"#, "broken"]
    for reply in bad {
      IOSCoreBridge.suspendReply = reply; controller.start(); await pause()
      check(manager.connection.starts == 0, "invalid boolean/error/nil admitted start")
      await stop()
    }
    IOSCoreBridge.suspendReply = #"{"result":true,"error":null}"#
    controller.start(); await until("valid bool did not start") { manager.connection.starts == 1 }
  } else if caseName == "offline-config" {
    _ = await router.invoke(config)
    check(IOSCoreBridge.calls.contains("setupConfig"), "initial offline App configuration lost")
    check(!IOSCoreBridge.calls.contains("suspendDnsListener"), "offline launch unexpectedly extension-owned")
  } else if caseName == "active-config" || caseName == "connecting-config" {
    await post(caseName == "active-config" ? .connected : .connecting)
    IOSCoreBridge.calls.removeAll()
    _ = await router.invoke(config)
    check(!IOSCoreBridge.calls.contains("resumeDnsListener"), "NE active configuration resumed App DNS")
    check(IOSCoreBridge.calls.contains("setupConfig"), "App raw config phase skipped")
    // Unknown initial owner must have been quiesced, including cold connecting.
    check(IOSCoreBridge.calls.contains("suspendDnsListener") || caseName == "active-config", "connecting configuration not quiesced")
  } else if caseName == "suspend-false" {
    IOSCoreBridge.suspendReply = #"{"result":false,"error":null}"#
    controller.start(); await pause()
    check(manager.connection.starts == 0, "false suspend admitted start")
  } else if caseName == "stop-failure" {
    controller.start(); await until("start missing") { manager.connection.starts == 1 }
    await post(.connected)
    manager.connection.holdStop = true
    controller.stop(); await pause()
    try? await Task.sleep(nanoseconds:5_300_000_000)
    check(!IOSCoreBridge.calls.contains("resumeDnsListener"), "stop timeout resumed App during disconnecting")
    _ = await router.invoke(config)
    check(!IOSCoreBridge.calls.contains("resumeDnsListener"), "offline-looking route stole active NE port")
    await post(.disconnected)
    await until("late terminal stop not restored") { IOSCoreBridge.calls.contains("resumeDnsListener") }
  } else if caseName == "resume-false" {
    controller.start(); await until("start missing") { manager.connection.starts == 1 }
    IOSCoreBridge.resumeReply = #"{"result":false}"#
    await stop()
    let result = await router.invoke(config)
    check(result.contains("app_dns_handoff_failed"), "false resume treated as offline ownership success")
    IOSCoreBridge.resumeReply = #"{"result":true}"#
    _ = await router.invoke(config)
    check(IOSCoreBridge.calls.last == "setupConfig", "retry failed to recover current offline config")
  } else if caseName == "late-resume" {
    controller.start(); await until("start missing") { manager.connection.starts == 1 }
    await post(.connected)
    IOSCoreBridge.holdResume = true
    await stop()
    await until("resume barrier missing") { IOSCoreBridge.heldResume != nil }
    controller.start(); await pause()
    check(manager.connection.starts == 1, "start bypassed pending resume")
    let old = IOSCoreBridge.heldResume!; IOSCoreBridge.heldResume = nil; IOSCoreBridge.holdResume = false
    old(#"{"result":true,"error":null}"#)
    await until("new start failed after late resume") { manager.connection.starts == 2 }
    check(IOSCoreBridge.calls.last == "suspendDnsListener", "late resume stole new start ownership")
  } else if caseName == "stop-restore" || caseName == "stale-status" {
    controller.start(); await until("start missing") { manager.connection.starts == 1 }
    await post(.connected)
    manager.connection.holdStop = true
    controller.stop(); await pause()
    check(!IOSCoreBridge.calls.contains("resumeDnsListener"), "App resumed while disconnecting")
    await post(.disconnected)
    await until("terminal stop did not restore App DNS") { IOSCoreBridge.calls.contains("resumeDnsListener") }
    _ = await router.invoke(config)
    check(IOSCoreBridge.calls.last == "setupConfig", "offline setup failed after terminal restore")
    if caseName == "stale-status" {
      controller.start(); await until("new start missing") { manager.connection.starts == 2 }
      let count = IOSCoreBridge.calls.filter { $0 == "resumeDnsListener" }.count
      let foreign = NETunnelProviderManager(); foreign.connection.status = .disconnected
      NotificationCenter.default.post(name:.NEVPNStatusDidChange,object:foreign.connection)
      // A queued old notification still reads the actual current connecting status.
      NotificationCenter.default.post(name:.NEVPNStatusDidChange,object:manager.connection)
      await pause()
      check(IOSCoreBridge.calls.filter { $0 == "resumeDnsListener" }.count == count, "stale stop seized App DNS")
    }
  } else {
    IOSCoreBridge.holdSuspend = true
    if caseName == "toggle-start" { controller.toggle() } else { controller.start() }
    await pause()
    check(manager.connection.starts == 0, "start crossed unreleased App DNS listener")
    check(IOSCoreBridge.heldSuspend != nil, "missing App suspend barrier")
    if caseName == "superseded-start" { controller.stop(); controller.start() }
    if caseName == "terminal-stop" { controller.stop() }
    let old = IOSCoreBridge.heldSuspend!; IOSCoreBridge.heldSuspend = nil; IOSCoreBridge.holdSuspend = false
    old(#"{"result":true,"error":null}"#)
    await pause()
    if caseName == "terminal-stop" {
      check(manager.connection.starts == 0, "retired start crossed terminal stop")
      check(IOSCoreBridge.calls.contains("resumeDnsListener"), "terminal stop did not recover App owner")
    } else {
      check(manager.connection.starts == 1, "only current start must dispatch once")
    }
  }
  UserDefaults(suiteName:shared.appGroupIdentifier)?.removePersistentDomain(forName:shared.appGroupIdentifier)
  try? FileManager.default.removeItem(at:fixtureRoot)
  print("PASS DNS \(caseName)"); exit(0)
}
RunLoop.main.run()
