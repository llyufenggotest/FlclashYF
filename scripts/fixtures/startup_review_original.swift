import Foundation
import Darwin
let mode = CommandLine.arguments[1]
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { print("FAIL REVIEW \(mode): \(message)"); exit(1) }
}
let defaults = UserDefaults(suiteName: "group.test.attempt")!
defaults.removePersistentDomain(forName: "group.test.attempt")
defer { defaults.removePersistentDomain(forName: "group.test.attempt") }
var options: [String: Any] = ["enable": true, "port":7890, "ipv6":false, "captureDns":true,
  "accessControlProps": [String: Any](), "allowBypass":false, "systemProxy":false,
  "suspendSupport":false, "bypassDomain": [String](), "stack":"mixed"]
func shared(_ options: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject:["vpnOptions":options])
}
let store = SharedStateStore()
if mode == "routes" || mode == "bypass" {
  let key = mode == "routes" ? "routeAddress" : "bypassDomain"
  options[key] = (0..<257).map { mode == "routes" ? "10.\($0 / 256).\($0 % 256).0/24" : "h\($0).example.test" }
  let data = try shared(options)
  let legacy = try JSONDecoder().decode(PacketTunnelVPNOptions.self, from: JSONSerialization.data(withJSONObject:options))
  require((mode == "routes" ? legacy.routeAddress : legacy.bypassDomain).count == 257, "baseline typed decoder rejected counterexample")
  require(data.count < StartupEnvelope.maxBytes, "counterexample is not within 32 KiB")
  require(store.saveSharedState(data), "valid 257-entry list rejected before start/sync")
} else {
  let original = try shared(options)
  require(store.saveSharedState(original), "valid initial state rejected")
  let running = try StartupEnvelope.make(shared:original)
  // Exact production receiver stores the stripped accepted options this way.
  PacketTunnelSharedStateStore().saveRunTime(vpnOptions: running.options)
  options["port"] = 7891
  let changed = try shared(options)
  require(store.saveSharedState(changed), "valid changed state rejected")
  let active = store.activeVpnOptions()
  require(active != nil, "connected configuration edit made active options nil; direct VpnManager caller suppresses restart warning")
  let object = try JSONSerialization.jsonObject(with:Data(active!.utf8)) as! [String:Any]
  require((object["port"] as? Int) == 7890, "active snapshot was overwritten by current desired state")
}
print("PASS REVIEW \(mode)")
