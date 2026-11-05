import Foundation
import Darwin
let mode = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { print("FAIL IPAD \(mode): \(message)"); exit(1) }
}
#if IPAD_BASELINE
// Same observable export requirement, through the baseline public record API.
SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "test.attempt")
SwitchDiagnostics.record("ipad_runner_launch")
let legacy = directory.appendingPathComponent("ipad-diagnostic-local.jsonl")
check(FileManager.default.fileExists(atPath: legacy.path), "independent Runner evidence absent")
#else
SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "test.attempt")
SwitchDiagnostics.setIPadTestStorage(local: mode == "sink-failure" ? directory.appendingPathComponent("absent/child") : directory, sharedUnavailable: true)
fixtureContainer = nil
func exported(_ callback: @escaping (String) -> Void) {
  SwitchDiagnostics.exportIPadDiagnostics { text in
    check(text.contains("iPadDiagnostic-v1"), "schema missing")
    check(text.contains("sharedSource=unavailable"), "nil shared source not explicit")
    check(!text.contains("PRIVATE_SENTINEL"), "privacy poison escaped")
    check(text.contains("container_identity=not_proved"), "false shared-identity proof")
    callback(text)
  }
}
if mode == "queue-caps" {
  let held = DispatchSemaphore(value: 0)
  SwitchDiagnostics.holdIPadQueue(held)
  for _ in 0..<20000 { SwitchDiagnostics.record("ipad_provider_entry") }
  let budget = SwitchDiagnostics.iPadQueueBudget()
  check(budget.jobs <= 64 && budget.bytes <= 65536 && budget.dropped > 0, "queue cap")
  held.signal()
  exported { text in check(text.utf8.count <= 800000, "export cap"); print("PASS IPAD \(mode)"); exit(0) }
} else if ["privacy", "sink-failure", "no-entry", "underlying"].contains(mode) {
  let error = NSError(domain: "com.flclashyf.iPadDiagnostic", code: 3,
    userInfo: [NSLocalizedDescriptionKey: "PRIVATE_SENTINEL", "PRIVATE_SENTINEL": "PRIVATE_SENTINEL",
      NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13,
        userInfo: [NSFilePathErrorKey: "PRIVATE_SENTINEL"])])
  let fields = SwitchDiagnostics.iPadErrorFields(mode == "no-entry" ? nil : error)
  if mode == "underlying" {
    check(fields["provider_stage"] == "network_settings", "known provider stage lost")
    check(fields["underlying_domain"] == "NSPOSIXErrorDomain" && fields["underlying_code"] == "13", "underlying classification lost")
    let archived = try! NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
    let bridged = try! NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: archived)!
    check(SwitchDiagnostics.iPadErrorFields(bridged)["provider_stage"] == "network_settings", "NSError secure bridge lost stage")
  }
  if mode == "privacy" {
    let poison = #"{"schema":"PRIVATE_SENTINEL","stage":"disconnect","path":"PRIVATE_SENTINEL"}"# + "\n"
    try! poison.write(to: directory.appendingPathComponent("ipad-diagnostic-local.jsonl"), atomically: true, encoding: .utf8)
  }
  SwitchDiagnostics.recordIPad("disconnect", fields: fields.merging(["path":"PRIVATE_SENTINEL", "schema":"PRIVATE_SENTINEL", "error_code":"PRIVATE_SENTINEL", "PRIVATE_SENTINEL":"PRIVATE_SENTINEL"]) { old, _ in old })
  SwitchDiagnostics.recordIPad("PRIVATE_SENTINEL", fields: [:])
  exported { text in
    check(text.contains("disconnect"), "fallback lost admitted event")
    if mode == "sink-failure" { check(text.contains("runnerLocal=unreadable_or_absent"), "failed sink claimed readable") }
    if mode == "no-entry" { check(text.contains("no_error_no_entry_proof"), "nil error invented provider entry") }
    print("PASS IPAD \(mode)"); exit(0)
  }
} else {
  Task { @MainActor in
    let provider = PacketTunnelProvider()
    if mode == "provider-network-error" {
      fixtureContainer = directory
      try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let options: [String: Any] = ["port": 7890, "ipv6": false, "captureDns": true, "systemProxy": false, "bypassDomain": [], "stack": "gvisor", "mtu": 1500, "routeAddress": [], "disableIcmpForwarding": false, "endpointIndependentNat": false, "congestionController": "", "recvMsgX": false, "sendMsgX": false, "includeAllNetworks": false, "excludeLocalNetworks": true, "excludeAPNs": true, "excludeCellularServices": true, "enforceRoutes": false, "excludeDeviceCommunication": true]
      UserDefaults(suiteName: "group.test.attempt")!.set(try! JSONSerialization.data(withJSONObject: ["vpnOptions":options]), forKey: "sharedState")
    }
    var received: Error?
    provider.startTunnel(options: nil) { received = $0 }
    if mode == "provider-network-error" {
      check(provider.heldSettings != nil, "network stage not reached")
      provider.heldSettings?(NSError(domain: NSPOSIXErrorDomain, code:13, userInfo:[NSLocalizedDescriptionKey:"PRIVATE_SENTINEL"]))
      try? await Task.sleep(nanoseconds: 50000000)
    }
    guard let error = received as NSError? else { check(false, "provider failure completion absent"); return }
    check(error.domain == "com.flclashyf.iPadDiagnostic", "provider fixed domain absent")
    check(error.code == (mode == "provider-network-error" ? 3 : 1), "provider wrong stage code")
    check(error.userInfo[NSUnderlyingErrorKey] != nil, "original error not preserved")
    // Exercise actual Coordinator fetch callback and generation ownership.
    let manager = NETunnelProviderManager()
    manager.connection.status = .disconnected
    manager.connection.lastError = error
    let shared = SharedStateStore()
  _ = shared.saveSharedState(Data(#"{"vpnOptions":{"port":7890,"ipv6":false,"captureDns":true,"systemProxy":false,"stack":"mixed"}}"#.utf8))
    let store = TunnelManagerStore(sharedStateStore: shared, networkExtensionIdentifier: "test.attempt.NECore", localizedDescription: "test")
    let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.attempt.NECore"
    manager.protocolConfiguration = proto
    NETunnelProviderManager.managers = [manager]
    let coordinator = TunnelCoordinator(managerStore: store, onTunnelStateChanged: {_ in}, onConnectionStateChanged: {_ in}, onExternalStart: {}, onExternalStop: {})
    coordinator.submitTunnelRequest(target: .running)
    try? await Task.sleep(nanoseconds: 100000000)
    check(manager.connection.status == .connecting, "runner not connecting")
    for status in [NEVPNStatus.disconnecting, .disconnected] {
      manager.connection.status = status
      coordinator.handleTunnelStatusNotification(Notification(name: .NEVPNStatusDidChange, object: manager.connection))
    }
    try? await Task.sleep(nanoseconds: 100000000)
    check(manager.connection.fetches == 1, "Runner fetch must sample exactly once")
    exported { text in
      check(text.contains(mode == "provider-network-error" ? "network_settings" : "rpc_publication"), "provider stage did not reach Runner export")
      check(text.contains("provider_entry_proved"), "fixed error bridge not collected by Runner")
      print("PASS IPAD \(mode)"); exit(0)
    }
  }
}
RunLoop.main.run()
#endif
