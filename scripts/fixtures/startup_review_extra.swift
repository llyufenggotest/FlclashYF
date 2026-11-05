import Foundation
import Darwin
let mode = CommandLine.arguments[1]
func require(_ ok: Bool, _ message: String) {
  if !ok { print("FAIL EXTRA \(mode): \(message)"); exit(1) }
}
let defaults = UserDefaults(suiteName: "group.test.attempt")!
defaults.removePersistentDomain(forName: "group.test.attempt")
UserDefaults.standard.removeObject(forKey: "startupDartSnapshotsV1")
let store = SharedStateStore()
let receiver = PacketTunnelSharedStateStore()
var options: [String: Any] = ["enable":true,"port":7890,"ipv6":false,"captureDns":true,
  "accessControlProps":["private":"ACCESS_SENTINEL"],"allowBypass":false,
  "systemProxy":false,"suspendSupport":false,"bypassDomain":[String](),"stack":"mixed"]
func shared() throws -> Data { try JSONSerialization.data(withJSONObject:["vpnOptions":options,"setupParams":["private":"YAML_SENTINEL"]]) }
func activeObject() throws -> [String: Any] {
  let text = store.activeVpnOptions()
  require(text != nil, "active startup snapshot unavailable")
  return try JSONSerialization.jsonObject(with:Data(text!.utf8)) as! [String:Any]
}
func finish() -> Never {
  defaults.removePersistentDomain(forName:"group.test.attempt")
  UserDefaults.standard.removeObject(forKey:"startupDartSnapshotsV1")
  try? FileManager.default.removeItem(at:fixtureRoot)
  print("PASS EXTRA \(mode)"); exit(0)
}
require(store.saveSharedState(try shared()), "initial save failed")
let running = try store.loadStartupEnvelope()
require(!String(data:running.data,encoding:.utf8)!.contains("SENTINEL"), "private fields entered envelope")
if mode == "budget" {
  options["routeAddress"] = (0..<1024).map { "10.\($0 / 256).\($0 % 256).0/24" }
  require(store.saveSharedState(try shared()), "budget-valid 1024 routes rejected")
  let accepted = try store.loadStartupEnvelope()
  let object = try JSONSerialization.jsonObject(with:accepted.options) as! [String:Any]
  require((object["routeAddress"] as! [String]).count == 1024, "routes truncated")
  options["routeAddress"] = Array(repeating:"10.0.0.0/24",count:4000)
  require(!store.saveSharedState(try shared()), "oversize accepted")
  options["routeAddress"] = [1,2]
  require(!store.saveSharedState(try shared()), "wrong list type accepted")
  finish()
}
if mode == "provider-receipt" {
  try FileManager.default.createDirectory(at:fixtureRoot,withIntermediateDirectories:true)
  let provider = PacketTunnelProvider()
  (provider.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration = [StartupEnvelope.key:running.data]
  var completions = 0
  provider.startTunnel(options:[StartupEnvelope.key:running.data as NSData]) { error in
    require(error == nil, "provider startup failed"); completions += 1
  }
  require(provider.heldSettings != nil, "provider did not reach settings")
  provider.heldSettings?(nil)
  DispatchQueue.main.asyncAfter(deadline:.now() + 0.05) {
    require(NECoreBridge.heldSetup != nil, "provider did not reach setup")
    NECoreBridge.heldSetup?(nil)
    DispatchQueue.main.asyncAfter(deadline:.now() + 0.05) {
      require(completions == 1, "provider did not complete")
      require(defaults.string(forKey:"activeStartupRevision") == running.revision.uuidString, "provider receipt revision missing")
      options["port"] = 7891
      require(store.saveSharedState(try! shared()), "edit failed")
      let active = try! activeObject()
      require(active["port"] as? Int == 7890, "provider active history changed")
      provider.stopTunnel(with:.none) { finish() }
    }
  }
  RunLoop.main.run()
} else {
  receiver.saveRunTime(vpnOptions:running.options,revision:running.revision)
  options["allowBypass"] = true
  require(store.saveSharedState(try shared()), "edit rejected")
  let active = try activeObject()
  require(active["allowBypass"] as? Bool == false, "current desired replaced active allowBypass")
  let relaunched = SharedStateStore()
  require(relaunched.activeVpnOptions() != nil, "Runner-local snapshot did not survive store reload")
  // Missing shared readback, unknown receipt and mismatched control must not
  // turn a locally saved desired snapshot into fabricated running state.
  defaults.removeObject(forKey:"activeStartupRevision")
  require(store.activeVpnOptions() == nil, "receipt-less stripped options fabricated active")
  defaults.set(UUID().uuidString,forKey:"activeStartupRevision")
  require(store.activeVpnOptions() == nil, "unknown revision fabricated active")
  defaults.set(running.revision.uuidString,forKey:"activeStartupRevision")
  var wrong = try JSONSerialization.jsonObject(with:running.options) as! [String:Any]
  wrong["port"] = 7892
  defaults.set(try JSONSerialization.data(withJSONObject:wrong),forKey:"activeVpnOptions")
  require(store.activeVpnOptions() == nil, "mismatched control accepted")
  defaults.removeObject(forKey:"activeVpnOptions")
  require(store.activeVpnOptions() == nil, "missing NE readback fabricated active")
  // Existing legacy full-payload contract remains supported without revision.
  receiver.saveRunTime(vpnOptions:try JSONSerialization.data(withJSONObject:options))
  require(store.activeVpnOptions() != nil, "legacy full active snapshot lost")
  receiver.clearRunTime()
  require(store.activeVpnOptions() == nil, "stop retained active")
  finish()
}
