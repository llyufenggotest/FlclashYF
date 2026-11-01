// Compiled with unmodified production coordinator/types/logger method bodies.
// Only system connection/preferences boundaries are doubled by the gate.
let caseName = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { print("FAIL START-DIAGNOSTICS \(caseName): \(message)"); exit(1) }
}
SwitchDiagnostics.setTestDirectory(directory, bundleIdentifier: "test.diagnostics")
func rows() -> [[String: Any]] {
  let path = directory.appendingPathComponent("ios-switch-Runner.log")
  guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
  check(!text.contains("PRIVATE_SENTINEL"), "sensitive text leaked")
  return text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
}
if caseName == "payloads" {
  let samples: [(String?, String)] = [
    (#"{"result":{"value":15,"name":"PRIVATE_SENTINEL","url":"PRIVATE_SENTINEL"}}"#, "delay_positive"),
    (#"{"result":{"value":-1},"error":null}"#, "delay_negative"),
    (#"{"result":{"value":0}}"#, "delay_invalid"),
    (#"{"result":{"value":null}}"#, "delay_missing"),
    (#"{"result":null}"#, "delay_missing"), (nil, "delay_missing"),
    (#"{"result":{}}"#, "delay_missing"), (#"{}"#, "delay_missing"),
    (#"{"result":{"value":true}}"#, "delay_invalid"),
    (#"{"result":{"value":"15"}}"#, "delay_invalid"),
    (#"{"result":{"value":1.5}}"#, "delay_invalid"),
    (#"{"result":{"value":2147483648}}"#, "delay_invalid"),
    (#"{"result":[]}"#, "delay_invalid"), ("{broken", "delay_invalid"),
    (String(repeating:"PRIVATE_SENTINEL",count:400), "delay_invalid"),
    (#"{"error":{"message":"PRIVATE_SENTINEL","code":"PRIVATE_SENTINEL"},"result":null}"#, "core_error_response")
  ]
  for (text, expected) in samples {
    let bytes = text.map { Data($0.utf8) }; let before = bytes
    let classification = SwitchDiagnostics.responseErrorType(bytes, method:"asyncTestDelay")
    check(classification == expected, "delay classification \(expected)")
    check(bytes == before, "wire bytes changed")
    if let text { check(SwitchDiagnostics.responseErrorType(text, method:"asyncTestDelay") == expected, "string/data classification differs") }
    SwitchDiagnostics.record("core_request_reply", fields:["method":"asyncTestDelay", "error_type":classification])
  }
  for method in ["getTraffic", "getTotalTraffic"] {
    check(SwitchDiagnostics.responseErrorType(#"{"result":{"up":1,"down":2}}"#,method:method) == "none", "omitempty traffic success")
    check(SwitchDiagnostics.responseErrorType(#"{}"#,method:method) == "unclassified_response", "empty object is not success")
  }
  #if !PAYLOAD_BASELINE
  for domain in ["PRIVATE_SENTINEL", "NEVPNConnectionErrorDomain"] {
    var fields = SwitchDiagnostics.disconnectErrorFields(NSError(domain:domain, code:-17,
      userInfo:[NSLocalizedDescriptionKey:"PRIVATE_SENTINEL"]))
    check(fields["error_domain"] == (domain == "PRIVATE_SENTINEL" ? "unknown" : domain), "domain redaction")
    fields["stage"] = "start_tunnel"; fields["generation"] = "1"
    SwitchDiagnostics.record("tunnel_start_disconnect_error", fields:fields)
  }
  SwitchDiagnostics.record("tunnel_start_disconnect_error",fields:["error_code":"PRIVATE_SENTINEL", "error_domain":"PRIVATE_SENTINEL"])
  let logged = rows()
  check(logged.count == samples.count + 3, "one bounded existing event per reply")
  check(logged[logged.count-2]["error_code"] as? String == "-17", "signed code persistence")
  check(logged.last?["error_code"] == nil, "malicious numeric rejected")
  #endif
  print("PASS START-DIAGNOSTICS \(caseName)"); exit(0)
}
Task { @MainActor in
  let manager = NETunnelProviderManager(); manager.connection.status = .disconnected
  let store = TunnelManagerStore(manager)
  var states: [String] = []
  let coordinator = TunnelCoordinator(managerStore:store, onTunnelStateChanged:{ _ in },
    onConnectionStateChanged:{ states.append($0) }, onExternalStart:{}, onExternalStop:{})
  @MainActor func pause() async { try? await Task.sleep(nanoseconds:80_000_000) }
  @MainActor func post(_ status: NEVPNStatus) {
    manager.connection.status = status
    coordinator.handleTunnelStatusNotification(Notification(name:Notification.Name("test.status"),object:manager.connection))
  }
  @MainActor func start() async {
    coordinator.submitTunnelRequest(target:.running)
    await pause()
    check(manager.connection.status == .connecting, "start must reach connecting")
  }
  await start()
  if caseName == "normal-connect" {
    post(.connected); await pause(); post(.disconnecting); post(.disconnected); await pause()
    check(manager.connection.fetches == 0, "normal connect must not sample startup failure")
  } else if caseName == "user-stop" {
    coordinator.submitTunnelRequest(target:.stopped); await pause(); post(.disconnected); await pause()
    check(manager.connection.fetches == 0, "user stop must not sample failure")
  } else {
    post(.disconnecting); post(.disconnected); post(.disconnected); await pause()
    check(manager.connection.fetches == 1, "2-5-1 must fetch exactly once")
    check(states.last == "disconnected", "fetch callback blocked startup completion")
    let old = manager.connection.pendingDisconnect.removeFirst()
    if caseName == "late-generation" {
      await start()
      old(NSError(domain:"PRIVATE_SENTINEL",code:-99,userInfo:[:]))
      await pause()
      check(rows().isEmpty, "late callback was attributed to new generation")
      check(states.last == "pending", "late callback changed lifecycle")
      post(.disconnecting); post(.disconnected); await pause()
      check(manager.connection.fetches == 2, "new generation missing its own fetch")
      manager.connection.pendingDisconnect.removeFirst()(nil); await pause()
    } else if caseName == "late-stop" {
      coordinator.submitTunnelRequest(target:.stopped); await pause()
      old(NSError(domain:"PRIVATE_SENTINEL",code:-99,userInfo:[:]))
      await pause(); check(rows().isEmpty, "late callback after stop was logged")
    } else {
      old(NSError(domain:"PRIVATE_SENTINEL",code:-99,userInfo:[NSLocalizedDescriptionKey:"PRIVATE_SENTINEL"]))
      await pause(); post(.disconnected); await pause()
      let logged = rows()
      check(logged.count == 1, "duplicate or missing disconnect record")
      check(logged[0]["error_domain"] as? String == "unknown", "unknown domain not redacted")
      check(logged[0]["error_code"] as? String == "-99", "signed code lost")
      check(logged[0]["generation"] as? String == "1", "wrong generation")
    }
    check(manager.connection.stops == 0, "diagnostics introduced cleanup stop")
  }
  print("PASS START-DIAGNOSTICS \(caseName)"); exit(0)
}
RunLoop.main.run()
