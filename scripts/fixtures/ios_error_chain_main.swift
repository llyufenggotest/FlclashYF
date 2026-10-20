// Whole production provider/controller/router/server; named framework and Go
// boundaries only. No manually supplied diagnostic fields in route assertions.
import Foundation
import CoreFoundation
import Darwin
let caseName = CommandLine.arguments[1]
let success = Data(#"{"result":{"up":1,"down":2},"error":null}"#.utf8)
let failure = Data(#"{"result":null,"error":{"code":"invalid_arguments","message":"private-token","details":{"arguments":"private-config"}}}"#.utf8)
let request = Data(#"{"method":"getTraffic","id":"chain-error"}"#.utf8)
enum PowerProbe {
  static let lock = NSLock()
  static var decodes = 0
  static func bump(_ key: String) { lock.lock(); decodes += 1; lock.unlock() }
  static func reset() { lock.lock(); decodes = 0; lock.unlock() }
}
func check(_ value: @autoclosure () -> Bool, _ name: String) {
  if !value() { print("FAIL ERROR CHAIN: \(name)"); exit(1) }
}
func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
func rows() -> [[String: Any]] {
  let url = fixtureRoot.appendingPathComponent("ios-switch-NECore.log")
  let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  check(!text.contains("private-token") && !text.contains("private-config"), "privacy")
  return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
}
func finish(_ metrics: [String: Any] = [:]) -> Never {
  let result: [String: Any] = ["fixture":"ios-error-production-chain-v1", "mode":caseName, "status":"pass", "failures":[], "metrics":metrics]
  print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
  exit(0)
}
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
SwitchDiagnostics.setTestDirectory(fixtureRoot, bundleIdentifier: "audit.error.NECore")
#if PROVIDER_FIXTURE
NECoreBridge.testReply = failure
let provider = PacketTunnelProvider()
var received: Data?
provider.handleAppMessage(request) { received = $0 }
while received == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(received == failure, "raw_wire_bytes")
let raw = rows()
check(raw.contains { $0["event"] as? String == "rpc_reply" && $0["request_id"] as? String == SwitchDiagnostics.requestID(request) && $0["error_type"] as? String == "core_error_response" }, "raw_reply_detail")
check(PowerProbe.decodes == 1, "raw_single_ingress_decode")
finish(["rows":raw,"decodes":PowerProbe.decodes,"wire_error_preserved":true])
#else
Task { @MainActor in
  if caseName == "classifier-boundaries" {
    let cases: [(Data?, String, String)] = [
      (failure,"getTraffic","core_error_response"),
      (success,"getTraffic","none"),
      (failure,"getTotalTraffic","core_error_response"),
      (nil,"getTraffic","nil_response"),
      (Data([0xff,0xfe]),"getTraffic","unclassified_response"),
      (Data("{broken".utf8),"getTraffic","unclassified_response"),
      (Data("{}".utf8),"getTraffic","unclassified_response"),
      (Data("[]".utf8),"getTraffic","unclassified_response"),
      (Data(repeating:32,count:4097),"getTraffic","unclassified_response"),
      (failure,"private-unknown-method","none"),
      (Data(#"{"error":false}"#.utf8),"getTraffic","core_error_response")
    ]
    for (data,method,expected) in cases {
      check(SwitchDiagnostics.responseErrorType(data,method:method) == expected, "classifier_\(expected)")
    }
    DispatchQueue.concurrentPerform(iterations: 400) { index in
      let data = index % 2 == 0 ? failure : success
      let expected = index % 2 == 0 ? "core_error_response" : "none"
      check(SwitchDiagnostics.responseErrorType(data,method:"getTraffic") == expected, "concurrent_classifier")
    }
    check(SwitchDiagnostics.responseErrorType(String(repeating:"x",count:4097),method:"getTraffic") == "unclassified_response", "string_bound")
    finish(["boundary_cases":cases.count,"concurrent_cases":400])
  }
  await ProviderMessageBridge.setTestRoot(fixtureRoot)
  let runnerStore = SharedStateStore()
  let neStore = PacketTunnelSharedStateStore()
  let manager = NETunnelProviderManager()
  let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = "test.attempt.NECore"
  manager.protocolConfiguration = proto
  NETunnelProviderManager.managers = [manager]
  let controller = TunnelController(sharedStateStore:runnerStore,onTunnelStateChanged:{ _ in },onConnectionStateChanged:{ _ in },onExternalStart:{},onExternalStop:{})
  let router = CoreMessageRouter(tunnelController:controller)
  let attempt = UUID()
  var invokes = 0
  let server = PacketTunnelCommandServer(sharedStateStore:neStore) { bytes, cb in
    check(bytes == request, "mailbox_request_changed")
    invokes += 1; cb(failure)
  }
  check(server.start(attempt:attempt), "server_start")
  IOSCoreBridge.testReply = String(decoding:failure,as:UTF8.self)
  router.updateTunnelState(caseName == "app-error" ? .stopped : .running)
  PowerProbe.reset()
  let response = await router.invoke(request)
  check(Data(response.utf8) == failure, "route_wire_changed")
  await pause()
  let logged = rows()
  let expectedEvents = caseName == "app-error" ? ["core_request_reply"] : ["rpc_reply","provider_request_reply","core_request_reply"]
  for event in expectedEvents {
    check(logged.contains { $0["event"] as? String == event && $0["request_id"] as? String == SwitchDiagnostics.requestID(request) && $0["error_type"] as? String == "core_error_response" && $0["response_bytes"] as? String == String(failure.count) }, "chain_detail_\(event)")
  }
  check(IOSCoreBridge.testCalls == (caseName == "app-error" ? 1 : 0), "business_error_app_fallback")
  check(invokes == (caseName == "app-error" ? 0 : 1), "business_error_retried")
  check(PowerProbe.decodes == (caseName == "app-error" ? 1 : 2), "one_decode_per_process_ingress")
  check(!runnerStore.isConfigurationRequestApplied(SwitchDiagnostics.requestID(request), owner:RPCOwner(attempt:attempt,generation:0,nonce:UUID())), "error_created_receipt")
  server.stop()
  finish(["rows":logged,"decodes":PowerProbe.decodes,"app_calls":IOSCoreBridge.testCalls,"ne_invokes":invokes,"wire_error_preserved":true])
}
RunLoop.main.run()
#endif
