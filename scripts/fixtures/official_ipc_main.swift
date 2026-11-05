import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { print("FAIL OFFICIAL IPC: \(message)"); exit(1) }
}
func pump(_ seconds: Double = 0.08) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
let mode = CommandLine.arguments[1]
defer { fixtureDefaults.removePersistentDomain(forName: fixtureSuite) }
let request = OfficialIPCWire.request(nonce: UUID())
if mode == "handler" {
  let provider = FixtureProvider()
  var response: Data?
  provider.handleAppMessage(request) { response = $0 }
  pump()
  check(response.flatMap { OfficialIPCWire.validate($0, request: request) } != nil, "actual handler did not echo reserved probe")
  check(NECoreBridge.calls == 0, "probe reached Core")
  for malformed in [OfficialIPCWire.magic, OfficialIPCWire.magic + Data(repeating: 0, count: 4096), OfficialIPCWire.magic + Data([2]) + Data(repeating: 0, count: 16)] {
    var count = 0
    provider.handleAppMessage(malformed) { value in check(value == nil, "malformed reply"); count += 1 }
    check(count == 1 && NECoreBridge.calls == 0, "malformed reached Core or callback not once")
  }
  provider.handleAppMessage(request, completionHandler: nil)
  check(NECoreBridge.calls == 0, "nil completion touched Core")
  response = nil
  provider.handleAppMessage(Data("original-unrelated".utf8)) { response = $0 }
  pump()
  check(response == NECoreBridge.reply && NECoreBridge.calls == 1, "offtarget original handler changed")
} else {
  MainActor.assumeIsolated {
    NETunnelProviderManager.managers = [NETunnelProviderManager()]
    NETunnelProviderSession.mode = mode
    let probe = OfficialIPCProbe()
    var replies: [String] = []
    if mode == "profile" { NETunnelProviderManager.managers = [] }
    if mode == "load-timeout" { NETunnelProviderManager.hold = true }
    probe.run { replies.append($0) }
    pump()
    if ["hold", "load-timeout"].contains(mode) {
      var busy = ""
      probe.run { busy = $0 }
      check(busy.contains("outcome=busy"), "single inflight broken")
      pump(8.1)
      check(replies.count == 1 && replies[0].contains("outcome=timeout"), "deadline completion")
      let late = NETunnelProviderSession.callback
      let lateLoad = NETunnelProviderManager.loadCallback
      NETunnelProviderManager.hold = false
      NETunnelProviderSession.mode = "echo"
      var next = ""
      probe.run { next = $0 }
      pump()
      check(next.contains("outcome=echo_verified"), "next generation blocked")
      late?(request); lateLoad?([], nil)
      pump()
      check(replies.count == 1 && OfficialIPCProbe.export().contains("outcome=echo_verified"), "late generation overwrote result")
    } else {
      check(replies.count == 1, "completion exactly once")
      let expected = ["echo": "echo_verified", "status": "echo_verified", "nil": "nil_response", "mismatch": "mismatch", "wrong-nonce": "mismatch", "wrong-receipt": "mismatch", "oversize": "mismatch", "error": "transport_error", "profile": "profile_unavailable"][mode]!
      check(replies[0].contains("outcome=\(expected)"), "wrong classification")
      let exported = OfficialIPCProbe.export()
      for secret in ["DO_NOT_EXPORT", "secret/raw/path", UUID().uuidString, "nonce="] { check(!exported.contains(secret), "privacy") }
      if mode == "status" { check(exported.contains("status_before=1") && exported.contains("status_after=2") && exported.contains("status_events=2"), "OS status change missing") }
      if mode == "profile" { check(NETunnelProviderSession.sends == 0, "missing profile sent") }
      if mode == "echo" {
        check(exported.contains("nonce_equal=true") && exported.contains("known_receipt=true"), "byte proof missing")
        check(!exported.contains(NETunnelProviderSession.lastRequest.base64EncodedString()), "raw nonce persisted")
      }
    }
  }
}
print("PASS OFFICIAL IPC \(mode)")
