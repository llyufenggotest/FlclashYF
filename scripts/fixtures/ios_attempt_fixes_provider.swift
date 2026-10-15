import Foundation
import Darwin
let caseName = CommandLine.arguments[1]
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
  if !ok() { print("FAIL NATIVE \(caseName): \(message)"); exit(1) }
}
func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
let defaults = UserDefaults(suiteName: "group.test.attempt")!
defaults.set(Data(#"{"vpnOptions":{"port":7890,"ipv6":false,"captureDns":true,"systemProxy":false,"bypassDomain":[],"stack":"mixed"}}"#.utf8), forKey: "sharedState")
Task { @MainActor in
  let provider = PacketTunnelProvider()
  var completions = 0, failures = 0, stops = 0
  let completion: (Error?) -> Void = { error in completions += 1; if error != nil { failures += 1 } }
  if caseName == "initial-publish-failure" {
    // Leave a real readable previous-process ready record; fail only the
    // first atomic replacement, not subsequent cleanup/unlink operations.
    RPCSession(version: RPCWire.version, attempt: UUID(), ready: true).publish(to: fixtureRoot)
    RPCSession.testFailNextPublication = true
    provider.startTunnel(options: nil, completionHandler: completion)
    check(RPCSession.read(from: fixtureRoot) == nil, "old ready file survived failed initial publication")
    check(completions == 1 && failures == 1, "failed not-ready publication did not fail startup immediately")
    check(provider.heldSettings == nil, "settings admitted after failed publication")
    provider.stopTunnel(with: .none) { stops += 1 }
    await pause()
    check(completions == 1 && stops == 1, "publication failure completed more than once")
  } else {
    provider.startTunnel(options: nil, completionHandler: completion)
    check(RPCSession.readPublished(from: fixtureRoot)?.ready == false, "cold attempt not published")
    let attempt = RPCSession.readPublished(from: fixtureRoot)!.attempt
    let cleanup = provider.testCapturedCleanup()!
    if caseName == "quicksetup-stop" {
      provider.heldSettings?(nil); await pause()
      check(NECoreBridge.heldSetup != nil, "quickSetup not held")
    }
    provider.stopTunnel(with: .none) { stops += 1 }
    check(RPCSession.readPublished(from: fixtureRoot) == nil, "cold stopped attempt remains published")
    check(completions == 1 && failures == 1 && stops == 1, "stop/start completion not exact once")
    if caseName == "quicksetup-stop" { NECoreBridge.heldSetup?(nil) }
    else { provider.heldSettings?(nil) }
    await pause(); await pause()
    check(RPCSession.read(from: fixtureRoot) == nil, "late callback republished stopped attempt")
    check(completions == 1, "late callback completed startup again")
    if caseName == "old-cleanup-new-attempt" {
      provider.startTunnel(options: nil, completionHandler: completion)
      let next = RPCSession.readPublished(from: fixtureRoot)!
      check(next.attempt != attempt, "new attempt not minted")
      cleanup.cleanup()
      check(RPCSession.readPublished(from: fixtureRoot) == next, "old cleanup retired new attempt")
      provider.stopTunnel(with: .none) {}
    }
  }
  defaults.removePersistentDomain(forName: "group.test.attempt")
  try? FileManager.default.removeItem(at: fixtureRoot)
  print("PASS NATIVE \(caseName)"); exit(0)
}
RunLoop.main.run()
