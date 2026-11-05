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
        guard let items = value as? [String], items.count <= 256,
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
