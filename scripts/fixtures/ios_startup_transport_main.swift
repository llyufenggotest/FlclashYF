import Foundation
import Darwin
let caseName = CommandLine.arguments[1]
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { print("FAIL TRANSPORT \(caseName): \(message)"); exit(1) }
}
let shared = Data(#"{"vpnOptions":{"port":7890,"ipv6":false,"captureDns":true,"systemProxy":false,"stack":"mixed"},"setupParams":{"private":"PRIVATE_SENTINEL"}}"#.utf8)
let envelope = try StartupEnvelope.make(shared: shared)
func reject(_ expected: StartupEnvelopeError, _ body: () throws -> Void) {
  do { try body(); check(false, "invalid candidate accepted") }
  catch { check((error as? StartupEnvelopeError) == expected, "wrong closed reason") }
}
if caseName == "validation" {
  check(!String(data: envelope.data, encoding: .utf8)!.contains("PRIVATE_SENTINEL"), "setup leaked into preferences")
  reject(.version) {
    var object = try JSONSerialization.jsonObject(with: envelope.data) as! [String: Any]
    object["version"] = 2
    _ = try StartupEnvelope.decode(JSONSerialization.data(withJSONObject: object))
  }
  reject(.oversize) { _ = try StartupEnvelope.decode(Data(repeating: 32, count: StartupEnvelope.maxBytes + 1)) }
  reject(.shape) { _ = try StartupEnvelope.decode(Data("broken".utf8)) }
  for key in ["port", "ipv6", "captureDns", "systemProxy", "stack"] {
    var object = try JSONSerialization.jsonObject(with: shared) as! [String: Any]
    var options = object["vpnOptions"] as! [String: Any]
    options.removeValue(forKey: key); object["vpnOptions"] = options
    reject(.optionsDecode) { _ = try StartupEnvelope.make(shared: JSONSerialization.data(withJSONObject: object)) }
    options[key] = ["poison"]; object["vpnOptions"] = options
    reject(.optionsDecode) { _ = try StartupEnvelope.make(shared: JSONSerialization.data(withJSONObject: object)) }
  }
  let absent = try StartupEnvelope.resolveStartup(manual: nil, persisted: nil)
  check(absent == nil, "legacy source lost")
  let cold = try StartupEnvelope.resolveStartup(manual: nil, persisted: [StartupEnvelope.key: envelope.data])
  check(cold?.1 == "provider_configuration", "cold persisted channel lost")
  let manual = try StartupEnvelope.resolveStartup(manual: [StartupEnvelope.key: envelope.data as NSData], persisted: [StartupEnvelope.key: envelope.data])
  check(manual?.1 == "options", "manual channel lost")
  reject(.stale) { _ = try StartupEnvelope.resolveStartup(manual: [StartupEnvelope.key: envelope.data as NSData], persisted: [StartupEnvelope.key: try StartupEnvelope.make(shared: shared).data]) }
  reject(.version) {
    var object = try JSONSerialization.jsonObject(with: envelope.data) as! [String: Any]; object["version"] = 9
    _ = try StartupEnvelope.resolveStartup(manual: nil, persisted: [StartupEnvelope.key: JSONSerialization.data(withJSONObject: object)])
  }
  let error = NSError(domain: "com.flclashyf.iPadDiagnostic", code: 205, userInfo: [NSLocalizedDescriptionKey:"PRIVATE_SENTINEL"])
  let archive = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
  let bridged = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: archive)!
  let directory = fixtureRoot.appendingPathComponent("diagnostics")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  SwitchDiagnostics.setTestDirectory(directory,bundleIdentifier:"test.attempt")
  SwitchDiagnostics.setIPadTestStorage(local:directory,sharedUnavailable:true)
  let fields = SwitchDiagnostics.iPadErrorFields(bridged)
  check(fields["receive_reason"] == "options_decode" && fields["provider_stage"] == "vpn_options", "closed bridge reason lost")
  SwitchDiagnostics.recordIPad("disconnect",fields:fields.merging(["receive_source":"PRIVATE_SENTINEL", "path":"PRIVATE_SENTINEL"]) { old,_ in old })
  SwitchDiagnostics.recordIPad("vpn_options",fields:["receive_source":"provider_configuration", "count":"256"])
  SwitchDiagnostics.exportIPadDiagnostics { text in
    check(text.contains("options_decode") && text.contains("provider_configuration"), "receipt writer reader allowlist lost field")
    check(!text.contains("PRIVATE_SENTINEL"), "poison privacy leaked")
    try? FileManager.default.removeItem(at:fixtureRoot)
    print("PASS TRANSPORT validation"); exit(0)
  }
  RunLoop.main.run()
}
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
let defaults = UserDefaults(suiteName: "group.test.attempt")!
defaults.removePersistentDomain(forName: "group.test.attempt")
if caseName == "legacy" { defaults.set(shared, forKey: "sharedState") }
#if TRANSPORT_CANDIDATE
if caseName == "legacy-reasons" {
  let store = PacketTunnelSharedStateStore()
  check(store.loadVPNOptionsSnapshot() == nil && store.lastOptionsFailure == .noData, "missing legacy reason")
  defaults.set(Data("broken".utf8), forKey:"sharedState")
  check(store.loadVPNOptionsSnapshot() == nil && store.lastOptionsFailure == .rootDecode, "root legacy reason")
  defaults.set(Data("{}".utf8), forKey:"sharedState")
  check(store.loadVPNOptionsSnapshot() == nil && store.lastOptionsFailure == .optionsMissing, "options legacy reason")
  defaults.removePersistentDomain(forName:"group.test.attempt")
  try? FileManager.default.removeItem(at:fixtureRoot)
  print("PASS TRANSPORT legacy-reasons"); exit(0)
}
#endif
Task { @MainActor in
  #if TRANSPORT_CANDIDATE
  if caseName == "manager" {
    let sharedStore = SharedStateStore()
    check(sharedStore.saveSharedState(shared), "sender rejected valid options")
    let manager = NETunnelProviderManager()
    let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.attempt.NECore"
    manager.protocolConfiguration = proto
    NETunnelProviderManager.managers = [manager]
    let store = TunnelManagerStore(sharedStateStore:sharedStore,networkExtensionIdentifier:"test.attempt.NECore",localizedDescription:"test")
    _ = try! await store.loadManager(createIfNeeded:false)
    let sent = try! store.prepareStartupEnvelope(for:manager)
    let manual = try! store.requireStartupEnvelope(sent,manager:manager)
    let received = try! StartupEnvelope.resolveStartup(manual:manual,persisted:proto.providerConfiguration)
    check(received?.0.revision == sent.revision, "sender receiver revision mismatch")
    let changed = Data(#"{"vpnOptions":{"port":7891,"ipv6":false,"captureDns":true,"systemProxy":false,"stack":"mixed"}}"#.utf8)
    check(sharedStore.saveSharedState(changed), "new config rejected")
    reject(.stale) { _ = try store.requireStartupEnvelope(sent,manager:manager) }
    let next = try! store.prepareStartupEnvelope(for:manager)
    check(next.revision != sent.revision, "changed state reused revision")
    try! await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in if let error { continuation.resume(throwing:error) } else { continuation.resume() } }
    }
    let disk = proto.providerConfiguration!
    proto.providerConfiguration = nil
    proto.providerConfiguration = disk
    _ = try! store.requireStartupEnvelope(next,manager:manager)
    let fullShared = Data(#"{"vpnOptions":{"enable":true,"accessControlProps":{},"allowBypass":false,"suspendSupport":false,"port":7891,"ipv6":false,"captureDns":true,"systemProxy":false,"stack":"mixed"}}"#.utf8)
    check(sharedStore.saveSharedState(fullShared), "full Dart payload rejected")
    let fullEnvelope = try! sharedStore.loadStartupEnvelope()
    PacketTunnelSharedStateStore().saveRunTime(vpnOptions: fullEnvelope.options, revision: fullEnvelope.revision)
    let activeText = sharedStore.activeVpnOptions()
    check(activeText?.contains("accessControlProps") == true, "active options lost Dart required fields")
    let before = proto.providerConfiguration![StartupEnvelope.key] as! Data
    check(!sharedStore.saveSharedState(Data("{}".utf8)), "invalid sender committed")
    check(proto.providerConfiguration![StartupEnvelope.key] as! Data == before, "invalid candidate changed preferences")
    defaults.removePersistentDomain(forName:"group.test.attempt")
    try? FileManager.default.removeItem(at:fixtureRoot)
    print("PASS TRANSPORT manager"); exit(0)
  }
  #endif
  let provider = PacketTunnelProvider()
  let proto = provider.protocolConfiguration as! NETunnelProviderProtocol
  if caseName != "legacy" { proto.providerConfiguration = [StartupEnvelope.key: envelope.data] }
  var manual: [String: NSObject]?
  if caseName == "manual" { manual = [StartupEnvelope.key: envelope.data as NSData] }
  if caseName == "stale" { manual = [StartupEnvelope.key: try! StartupEnvelope.make(shared: shared).data as NSData] }
  var completed = 0
  var returned: NSError?
  provider.startTunnel(options: manual) { error in completed += 1; returned = error as NSError? }
  if caseName == "stale" {
    check(completed == 1 && returned?.code == 209 && provider.heldSettings == nil, "stale manual did not fail closed")
  } else {
    check(provider.heldSettings != nil && completed == 0, "official channel failed before settings")
    provider.stopTunnel(with: .none) {}
    check(completed == 1, "stop did not complete once")
    provider.heldSettings?(nil)
    try? await Task.sleep(nanoseconds: 100_000_000)
    check(completed == 1 && RPCSession.read(from: fixtureRoot) == nil, "late callback escaped owner")
  }
  defaults.removePersistentDomain(forName: "group.test.attempt")
  try? FileManager.default.removeItem(at: fixtureRoot)
  print("PASS TRANSPORT \(caseName)"); exit(0)
}
RunLoop.main.run()
