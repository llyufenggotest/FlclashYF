import Foundation
import CoreFoundation

enum StartupEnvelopeError: String, Error {
  static let allReasons: [StartupEnvelopeError] = [.suiteUnavailable, .noData, .rootDecode, .optionsMissing, .optionsEncode, .optionsDecode, .version, .oversize, .shape, .stale]
  case suiteUnavailable = "suite_unavailable"
  case noData = "no_data_or_type"
  case rootDecode = "root_decode"
  case optionsMissing = "options_missing_or_type"
  case optionsEncode = "options_encode"
  case optionsDecode = "options_decode"
  case version = "bad_version"
  case oversize = "oversize"
  case shape = "envelope_shape"
  case stale = "stale_revision"
}

struct StartupEnvelope {
  static let key = "startupControlV1"
  static let maxBytes = 32 * 1024
  let revision: UUID
  let options: Data
  let data: Data

  static func integer(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      let result = Int(n.stringValue) else { return nil }
    return result
  }

  static func validateOptions(_ object: Any?) throws -> Data {
    guard let options = object as? [String: Any] else { throw StartupEnvelopeError.optionsMissing }
    let bools = ["ipv6", "captureDns", "systemProxy", "disableIcmpForwarding", "endpointIndependentNat", "recvMsgX", "sendMsgX", "includeAllNetworks", "excludeLocalNetworks", "excludeAPNs", "excludeCellularServices", "enforceRoutes", "excludeDeviceCommunication"]
    let keys = Set(bools + ["port", "stack", "mtu", "bypassDomain", "routeAddress", "congestionController"])
    guard Set(options.keys).isSubset(of: keys),
      let port = integer(options["port"]), (1...65535).contains(port),
      let stack = options["stack"] as? String, ["mips", "gvisor", "system", "mixed"].contains(stack)
    else { throw StartupEnvelopeError.optionsDecode }
    for key in bools {
      if let value = options[key] {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw StartupEnvelopeError.optionsDecode }
      } else if ["ipv6", "captureDns", "systemProxy"].contains(key) { throw StartupEnvelopeError.optionsDecode }
    }
    if let value = options["mtu"] {
      guard let mtu = integer(value), (576...65535).contains(mtu) else { throw StartupEnvelopeError.optionsDecode }
    }
    for key in ["bypassDomain", "routeAddress"] {
      if let value = options[key] {
        guard let items = value as? [String],
          items.allSatisfy({ $0.utf8.count <= 512 }) else { throw StartupEnvelopeError.optionsDecode }
      }
    }
    if let value = options["congestionController"] {
      guard let text = value as? String, text.utf8.count <= 32 else { throw StartupEnvelopeError.optionsDecode }
    }
    guard let bytes = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]) else { throw StartupEnvelopeError.optionsEncode }
    guard bytes.count <= maxBytes else { throw StartupEnvelopeError.oversize }
    return bytes
  }

  static func make(shared: Data, revision: UUID = UUID()) throws -> StartupEnvelope {
    guard let root = try? JSONSerialization.jsonObject(with: shared) as? [String: Any] else { throw StartupEnvelopeError.rootDecode }
    guard let raw = root["vpnOptions"] as? [String: Any] else { throw StartupEnvelopeError.optionsMissing }
    let omitted: Set<String> = ["enable", "accessControlProps", "allowBypass", "suspendSupport"]
    let options = try validateOptions(raw.filter { !omitted.contains($0.key) })
    let object = try JSONSerialization.jsonObject(with: options)
    let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "revision": revision.uuidString, "vpnOptions": object], options: [.sortedKeys])
    return try decode(bytes)
  }

  static func decode(_ value: Any) throws -> StartupEnvelope {
    guard let bytes = value as? Data else { throw StartupEnvelopeError.shape }
    guard bytes.count <= maxBytes else { throw StartupEnvelopeError.oversize }
    guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(root.keys) == Set(["version", "revision", "vpnOptions"]),
      let version = integer(root["version"]),
      let token = root["revision"] as? String, let revision = UUID(uuidString: token)
    else { throw StartupEnvelopeError.shape }
    guard version == 1 else { throw StartupEnvelopeError.version }
    let options = try validateOptions(root["vpnOptions"])
    return StartupEnvelope(revision: revision, options: options, data: bytes)
  }

  static func resolveStartup(manual: [String: NSObject]?, persisted: [String: Any]?) throws -> (StartupEnvelope, String)? {
    let stored: StartupEnvelope?
    if let value = persisted?[key] { stored = try decode(value) } else { stored = nil }
    if let value = manual?[key] {
      let override = try decode(value)
      guard let stored, override.revision == stored.revision, override.options == stored.options else { throw StartupEnvelopeError.stale }
      return (override, "options")
    }
    if let stored { return (stored, "provider_configuration") }
    return nil
  }
}

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Diagnostic only. Never changes the Core home, grants access, or gates legacy startup.
enum ConfigAccess {
  static let key = "configAccessV1"
  static let marker = ".config-access-v1"
  static let maxSetup = 1024 * 1024
  // Avoid collisions with legacy fixture globals named read.
  private static func readBytes(_ fd: Int32, _ pointer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, pointer, count)
    #else
    return Glibc.read(fd, pointer, count)
    #endif
  }
  struct Challenge: Codable, Equatable { let version: Int; let revision: UUID; let nonce: UUID }
  // The actual Dart write location is Runner-local, never in system preferences.
  static func written(path: String) -> Bool {
    let file = URL(fileURLWithPath: path)
    guard file.lastPathComponent == "config.yaml", probe(root: file.deletingLastPathComponent()).0 == 1 else { return false }
    UserDefaults.standard.set(file.deletingLastPathComponent().path, forKey: "configAccessLocalRootV1")
    UserDefaults.standard.set(UUID().uuidString, forKey: "configAccessLocalNonceV1")
    return true
  }
  static func attach(revision: UUID) -> Data? {
    guard let path = UserDefaults.standard.string(forKey: "configAccessLocalRootV1"),
      let token = UserDefaults.standard.string(forKey: "configAccessLocalNonceV1"), let nonce = UUID(uuidString: token)
    else { return nil }
    let challenge = Challenge(version: 1, revision: revision, nonce: nonce)
    guard let data = try? JSONEncoder().encode(challenge), data.count <= 512,
      (try? data.write(to: URL(fileURLWithPath: path).appendingPathComponent(marker), options: .atomic)) != nil else { return nil }
    return data
  }
  // 0 legacy absent, 1 matched, 2 missing/unreadable, 3 mismatch/old revision,
  // 4 invalid envelope, 5 nonregular/oversized marker. No receipt writes in NE.
  static func challenge(root: URL?, expected: Any?, revision: UUID?) -> Int {
    guard let expected else { return 0 }
    guard let bytes = expected as? Data, bytes.count <= 512,
      let wanted = try? JSONDecoder().decode(Challenge.self, from: bytes), wanted.version == 1,
      wanted.revision == revision else { return 4 }
    guard let root else { return 2 }
    let file = root.appendingPathComponent(marker)
    let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard fd >= 0 else { return 2 }; defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 512 else { return 5 }
    var buffer = [UInt8](repeating: 0, count: 513)
    let count = buffer.withUnsafeMutableBytes { readBytes(fd, $0.baseAddress, $0.count) }
    guard count >= 0, count <= 512,
      let actual = try? JSONDecoder().decode(Challenge.self, from: Data(buffer.prefix(Int(count)))) else { return 3 }
    return actual == wanted ? 1 : 3
  }
  static let errnos = [0, 2, 13, 1, 20, 5, 24, 23]
  static func errnoIndex(_ n: Int) -> Int { errnos.firstIndex(of: n) ?? 0 }
  // 0 root unavailable,1 open+bounded read OK,2 absent,3 denied/protected-unknown,
  // 4 invalid,5 nonregular,6 metadata failure,7 read failure,8 other open failure.
  static func probe(root: URL?) -> (Int, Int) {
    guard let root else { return (0,0) }
    let fd = open(root.appendingPathComponent("config.yaml").path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard fd >= 0 else {
      let e = Int(errno)
      return (e == 2 ? 2 : ([1,13].contains(e) ? 3 : ([20,40,62].contains(e) ? 4 : 8)), errnoIndex(e))
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return (6,errnoIndex(Int(errno))) }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return (5,0) }
    var byte: UInt8 = 0
    guard readBytes(fd, &byte, 1) >= 0 else { return (7,errnoIndex(Int(errno))) }
    return (1,0)
  }
  static func cocoaErrno(_ error: NSError) -> Int {
    var current: NSError? = error
    for _ in 0..<4 {
      guard let e = current else { break }
      if e.domain == NSPOSIXErrorDomain { return errnoIndex(e.code) }
      if e.domain == NSCocoaErrorDomain {
        if e.code == NSFileReadNoSuchFileError { return errnoIndex(2) }
        if e.code == NSFileReadNoPermissionError { return errnoIndex(13) }
      }
      current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return 0
  }
  struct Observation {
    let probe: Int; let errno: Int; let challenge: Int; let setup: Int; let source: Int; let homeEqual: Int
    func failure(_ result: Data) -> Int {
      let text = String(data: result.prefix(64), encoding: .utf8) ?? ""
      let parts = text.split(separator: ":", omittingEmptySubsequences: false)
      var stage = 0, kind = 0, coreErrno = 0
      if result.count <= 64, parts.count == 4, parts[0] == "@CA1",
        let s = Int(parts[1]), (1...5).contains(s), let k = Int(parts[2]), (0...3).contains(k),
        let e = Int(parts[3]), ConfigAccess.errnos.contains(e) {
        stage = s; kind = k; coreErrno = ConfigAccess.errnoIndex(e)
      }
      var n = stage
      for (value,radix) in [(kind,4),(coreErrno,8),(probe,9),(errno,8),(challenge,6),(setup,5),(source,4),(homeEqual,2)] { n = n * radix + value }
      return 1_000_000 + n
    }
  }
  static func initParams(root: URL?) -> String {
    let object: [String: Any] = ["home-dir": root?.path ?? "", "version": 0, "config-access-version": 1]
    guard let bytes = try? JSONSerialization.data(withJSONObject: object), let text = String(data: bytes, encoding: .utf8) else { return "{}" }
    return text
  }
  static func observe(root: URL?, initParams: String, setup: Data, source: Int, expected: Any?, revision: UUID?) -> Observation {
    let p = probe(root: root)
    let state: Int
    if setup.count > maxSetup { state = 4 }
    else if let object = (try? JSONSerialization.jsonObject(with: setup)) as? [String: Any] { state = object.isEmpty ? 1 : 2 }
    else { state = setup.isEmpty ? 0 : 3 }
    let args = (try? JSONSerialization.jsonObject(with: Data(initParams.utf8))) as? [String: Any]
    return Observation(probe: p.0, errno: p.1, challenge: challenge(root: root, expected: expected, revision: revision), setup: state, source: min(3,max(0,source)), homeEqual: args?["home-dir"] as? String == (root?.path ?? "") ? 1 : 0)
  }
  static func decodeFailure(_ code: Int) -> [String: String]? {
    guard code >= 1_000_000 else { return nil }
    var n = code - 1_000_000
    let names = ["home_equal","setup_source","setup_status","challenge_status","probe_errno","pre_probe","core_errno","core_kind"]
    let radices = [2,4,5,6,8,9,8,4]
    var fields = [String:String]()
    for (name,radix) in zip(names,radices) { fields[name] = String(n % radix); n /= radix }
    guard (0...5).contains(n) else { return nil }
    fields["core_stage"] = String(n)
    return fields
  }
  static func safeFields(_ fields: [String:String]) -> [String:String] {
    let bounds = ["home_equal":2,"setup_source":4,"setup_status":5,"challenge_status":6,"probe_errno":8,"pre_probe":9,"core_errno":8,"core_kind":4,"core_stage":6]
    return fields.filter { key,value in guard let bound = bounds[key], let n = Int(value) else { return false }; return n >= 0 && n < bound }
  }
}
