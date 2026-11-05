import Foundation
func check(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { print("FAIL CONFIG ACCESS: \(message)"); exit(1) } }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let config = root.appendingPathComponent("config.yaml")
let mode = CommandLine.arguments[2]
fixtureContainer = root
if mode == "baseline" {
  // Immutable production slice: the historical builder interpolates unescaped JSON.
  let store = PacketTunnelSharedStateStore()
  let blank: Bool
  // Baseline API is decoded on both builds; the observed JSON failure, not a
  // missing candidate symbol, is the immutable semantic RED.
  blank = (try? JSONSerialization.jsonObject(with: Data(store.makeInitParams().utf8))) != nil
  check(blank, "actual Core home JSON invalid")
  print("PASS CONFIG ACCESS baseline"); exit(0)
}
#if CONFIG_ACCESS_CANDIDATE
check(ConfigAccess.probe(root: nil).0 == 0, "nil root")
check(ConfigAccess.probe(root: root).0 == 2, "real absent open")
check(ConfigAccess.probe(root: root).1 == 1, "actual ENOENT")
try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
check(ConfigAccess.probe(root: root).0 == 5, "nonregular")
try FileManager.default.removeItem(at: config)
try Data("synthetic: true".utf8).write(to: config)
check(ConfigAccess.probe(root: root).0 == 1, "real bounded read")
check(ConfigAccess.written(path: config.path), "actual Dart write bridge")
let revision = UUID()
let expected = ConfigAccess.attach(revision: revision)!
check(expected.count <= 512, "small challenge")
check(ConfigAccess.challenge(root: root, expected: expected, revision: revision) == 1, "matched")
check(ConfigAccess.challenge(root: root, expected: expected, revision: UUID()) == 4, "old revision")
check(ConfigAccess.challenge(root: nil, expected: nil, revision: nil) == 0, "legacy cold start")
let different = root.appendingPathComponent("other")
try FileManager.default.createDirectory(at: different, withIntermediateDirectories: true)
check(ConfigAccess.challenge(root: different, expected: expected, revision: revision) == 2, "different namespace")
let challengeURL = root.appendingPathComponent(ConfigAccess.marker)
let old = ConfigAccess.Challenge(version: 1, revision: revision, nonce: UUID())
try JSONEncoder().encode(old).write(to: challengeURL)
check(ConfigAccess.challenge(root: root, expected: expected, revision: revision) == 3, "old owner nonce")
try Data(repeating: 1, count: 1024).write(to: challengeURL)
check(ConfigAccess.challenge(root: root, expected: expected, revision: revision) == 5, "oversize poison")
let before = try Data(contentsOf: challengeURL)
_ = ConfigAccess.challenge(root: root, expected: Data("PRIVATE_PATH".utf8), revision: revision)
let after = try Data(contentsOf: challengeURL)
check(after == before, "read only invalid owner")
let initParams = ConfigAccess.initParams(root: root)
let json = try JSONSerialization.jsonObject(with: Data(initParams.utf8)) as! [String:Any]
check(json["home-dir"] as? String == root.path, "escaped actual home roundtrip")
let obs = ConfigAccess.observe(root: root, initParams: initParams, setup: Data("{}".utf8), source: 1, expected: expected, revision: revision)
let code = obs.failure(Data("@CA1:4:2:13".utf8))
let fields = ConfigAccess.decodeFailure(code)!
check(fields["core_stage"] == "4" && fields["core_errno"] == "2", "original error fixed numeric bridge")
check(fields["home_equal"] == "1" && fields["pre_probe"] == "1", "preprobe actual same home")
check(ConfigAccess.decodeFailure(302) == nil, "legacy separately recognized")
check(ConfigAccess.decodeFailure(-1) == nil && ConfigAccess.decodeFailure(Int.max) == nil, "poison code")
check(ConfigAccess.safeFields(["pre_probe":"PRIVATE","path":root.path]).isEmpty, "closed privacy")
check(ConfigAccess.cocoaErrno(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) == 2, "Cocoa permission")
check(ConfigAccess.cocoaErrno(NSError(domain: "private", code: 99, userInfo: [NSUnderlyingErrorKey:NSError(domain:NSPOSIXErrorDomain,code:2)])) == 1, "underlying POSIX")
let handle = try FileHandle(forWritingTo: config)
try handle.truncate(atOffset: 128 * 1024 * 1024); try handle.close()
check(ConfigAccess.probe(root: root).0 == 1, "large sparse config read remains bounded")
check(ConfigAccess.observe(root: root, initParams: initParams, setup: Data(repeating: 0, count: ConfigAccess.maxSetup+1), source: 1, expected: nil, revision: nil).setup == 4, "setup cap")
print("PASS CONFIG ACCESS candidate")
#endif
