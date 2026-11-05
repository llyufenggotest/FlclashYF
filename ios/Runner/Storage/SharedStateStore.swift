import Foundation
import WidgetKit

final class SharedStateStore {
  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"
  private let appliedConfigurationRequestKey = "appliedConfigurationRequest"
  private let eventQueueDirectoryName = "core-events"

  let appGroupIdentifier = "group.\(Bundle.main.bundleIdentifier!)"
  let eventNotificationName = "\(Bundle.main.bundleIdentifier!).NECore.event"

  func activeVpnOptions() -> String? {
    guard
      let data = UserDefaults(suiteName: appGroupIdentifier)?
        .data(forKey: "activeVpnOptions")
    else {
      return nil
    }
    guard let control = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if control["accessControlProps"] != nil { return String(data: data, encoding: .utf8) }
    // Only an NE-written receipt can identify a running official-channel snapshot.
    // Never fill historical Dart fields from the current desired shared state.
    guard let revision = UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: "activeStartupRevision"),
      let token = UUID(uuidString: revision),
      let saved = startupSnapshots[revision],
      let root = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
      let full = root["vpnOptions"] as? [String: Any],
      full["accessControlProps"] != nil, full["enable"] != nil,
      full["allowBypass"] != nil, full["suspendSupport"] != nil,
      let envelope = try? StartupEnvelope.make(shared: saved, revision: token),
      let active = try? StartupEnvelope.validateOptions(control), envelope.options == active,
      let bytes = try? JSONSerialization.data(withJSONObject: full) else { return nil }
    return String(data: bytes, encoding: .utf8)
  }

  private var startupEnvelope: StartupEnvelope?
  private var startupSharedData: Data?
  // Runner-local only: full Dart options (including access control) never enter
  // providerConfiguration or the bounded startup-control envelope.
  private let startupSnapshotsKey = "startupDartSnapshotsV1"
  private var startupSnapshots: [String: Data] {
    UserDefaults.standard.dictionary(forKey: startupSnapshotsKey) as? [String: Data] ?? [:]
  }

  private func rememberStartupSnapshot(_ shared: Data, envelope: StartupEnvelope) {
    guard let root = sharedStateJSON(from: shared),
      let options = root["vpnOptions"] as? [String: Any],
      let snapshot = try? JSONSerialization.data(withJSONObject: ["vpnOptions": options]) else { return }
    var snapshots = startupSnapshots
    // Retain the acknowledged running revision and the previous pending revision
    // while preparing the next one. Missing/pruned receipts fail closed to nil.
    let active = UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: "activeStartupRevision")
    let previous = startupEnvelope?.revision.uuidString
    snapshots = snapshots.filter { $0.key == active || $0.key == previous }
    snapshots[envelope.revision.uuidString] = snapshot
    UserDefaults.standard.set(snapshots, forKey: startupSnapshotsKey)
  }

  func loadStartupEnvelope() throws -> StartupEnvelope {
    if let startupEnvelope { return startupEnvelope }
    guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: sharedStateKey) else { throw StartupEnvelopeError.noData }
    let envelope = try StartupEnvelope.make(shared: data)
    rememberStartupSnapshot(data, envelope: envelope)
    startupEnvelope = envelope
    startupSharedData = data
    return envelope
  }

  func saveSharedState(_ data: Data) -> Bool {
    guard let candidate = try? StartupEnvelope.make(shared: data) else { return false }
    guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
      return false
    }
    let previousData = userDefaults.data(forKey: sharedStateKey)
    let previousControlDisplayState = controlDisplayState(from: previousData)
    let previousStatusDisplayState = statusDisplayState(from: previousData)
    if let json = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let setupData = try? JSONSerialization.data(withJSONObject: setupParams)
    {
      userDefaults.set(setupData, forKey: setupParamsKey)
    }
    if startupSharedData != data {
      rememberStartupSnapshot(data, envelope: candidate)
      startupEnvelope = candidate
      startupSharedData = data
    }
    userDefaults.set(data, forKey: sharedStateKey)
    userDefaults.synchronize()
    if previousControlDisplayState != controlDisplayState(from: data),
      #available(iOS 18.0, *)
    {
      ControlCenter.shared.reloadControls(
        ofKind: "\(Bundle.main.bundleIdentifier!).Widget"
      )
    }
    if previousStatusDisplayState != statusDisplayState(from: data) {
      WidgetCenter.shared.reloadTimelines(
        ofKind: "\(Bundle.main.bundleIdentifier!).Widget.Status"
      )
    }
    return true
  }

  private func sharedStateJSON(from data: Data?) -> [String: Any]? {
    guard let data else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func statusDisplayState(from data: Data?) -> NSDictionary {
    let json = sharedStateJSON(from: data)
    return [
      "currentProfileName": json?["currentProfileName"] ?? NSNull(),
      "widgetTheme": json?["widgetTheme"] ?? NSNull(),
    ]
  }

  private func controlDisplayState(
    from data: Data?
  ) -> (showProfileName: Bool, profileName: String?) {
    guard let json = sharedStateJSON(from: data) else {
      return (true, nil)
    }
    let showProfileName = json["showQuickSettingsProfileName"] as? Bool ?? true
    return (
      showProfileName,
      showProfileName ? json["currentProfileName"] as? String : nil
    )
  }

  func loadTunnelConfiguration() -> TunnelConfiguration {
    guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier),
      let data = userDefaults.data(forKey: sharedStateKey),
      let sharedState = try? JSONDecoder().decode(
        SharedStatePayload.self,
        from: data
      )
    else {
      return TunnelConfiguration()
    }
    return TunnelConfiguration(
      options: sharedState.vpnOptions?.networkExtensionOptions ?? NetworkExtensionOptions(),
      excludeSSIDs: sharedState.excludeSSIDs ?? [],
      alwaysOn: sharedState.alwaysOn ?? false
    )
  }

  func appGroupDirectory() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  }

  func eventQueueDirectory() -> URL? {
    appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  func runTime() -> Int {
    UserDefaults(suiteName: appGroupIdentifier)?
      .integer(forKey: runTimeKey) ?? 0
  }

  func isConfigurationRequestApplied(_ requestID: String, owner: RPCOwner) -> Bool {
    guard let session = RPCSession.read(from: appGroupDirectory()),
      session.attempt == owner.attempt,
      let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: appliedConfigurationRequestKey),
      let receipt = try? JSONDecoder().decode(RPCAppliedReceipt.self, from: data)
    else { return false }
    return receipt.version == RPCWire.version && receipt.owner == owner && receipt.requestID == requestID
  }

  func clearConfigurationRequestApplied() {
    let defaults = UserDefaults(suiteName: appGroupIdentifier)
    defaults?.removeObject(forKey: appliedConfigurationRequestKey)
    defaults?.synchronize()
  }
}

struct TunnelConfiguration {
  let options: NetworkExtensionOptions
  let excludeSSIDs: [String]
  let alwaysOn: Bool

  init(
    options: NetworkExtensionOptions = NetworkExtensionOptions(),
    excludeSSIDs: [String] = [],
    alwaysOn: Bool = false
  ) {
    self.options = options
    self.excludeSSIDs = excludeSSIDs
    self.alwaysOn = alwaysOn
  }
}

struct NetworkExtensionOptions {
  var includeAllNetworks = false
  var excludeLocalNetworks = true
  var excludeAPNs = true
  var excludeCellularServices = true
  var enforceRoutes = false
  var excludeDeviceCommunication = true
}

private struct SharedStatePayload: Decodable {
  let vpnOptions: VpnOptionsPayload?
  let excludeSSIDs: [String]?
  let alwaysOn: Bool?
}

private struct VpnOptionsPayload: Decodable {
  let includeAllNetworks: Bool?
  let excludeLocalNetworks: Bool?
  let excludeAPNs: Bool?
  let excludeCellularServices: Bool?
  let enforceRoutes: Bool?
  let excludeDeviceCommunication: Bool?

  var networkExtensionOptions: NetworkExtensionOptions {
    NetworkExtensionOptions(
      includeAllNetworks: includeAllNetworks ?? false,
      excludeLocalNetworks: excludeLocalNetworks ?? true,
      excludeAPNs: excludeAPNs ?? true,
      excludeCellularServices: excludeCellularServices ?? true,
      enforceRoutes: enforceRoutes ?? false,
      excludeDeviceCommunication: excludeDeviceCommunication ?? true
    )
  }
}
