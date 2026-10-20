import Foundation
import CoreFoundation
import NetworkExtension
import UIKit

@MainActor
final class TunnelController {
  private let sharedStateStore: SharedStateStore
  private let managerStore: TunnelManagerStore
  private let coordinator: TunnelCoordinator

  private var tunnelStatusObserver: NSObjectProtocol?
  private var appActiveObserver: NSObjectProtocol?
  private var appBackgroundObserver: NSObjectProtocol?
  private var appForegroundObserver: NSObjectProtocol?

  private let providerReadTimeout: TimeInterval = 8
  private let configurationTimeout: TimeInterval = 120
  private let maxInFlightProviderMessages = 8
  private var inFlightProviderMessages = 0

  private var configurationGeneration: UInt64 = 0
  private var configurationInFlight = false
  private let providerEpoch = RPCClientEpoch()
  private var observedProviderAttempt: UUID?
  private var managerRefreshTask: Task<Void, Error>?
  private let providerBridge: ProviderMessageBridge

  init(
    sharedStateStore: SharedStateStore,
    onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
    onConnectionStateChanged: @escaping (String) -> Void,
    onExternalStart: @escaping () -> Void,
    onExternalStop: @escaping () -> Void
  ) {
    let networkExtensionIdentifier =
      "\(Bundle.main.bundleIdentifier!).NECore"
    let managerStore = TunnelManagerStore(
      sharedStateStore: sharedStateStore,
      networkExtensionIdentifier: networkExtensionIdentifier,
      localizedDescription: "FlClash"
    )
    self.sharedStateStore = sharedStateStore
    self.managerStore = managerStore
    self.providerBridge = ProviderMessageBridge(
      appGroupIdentifier: sharedStateStore.appGroupIdentifier,
      commandNotificationName: "\(networkExtensionIdentifier).command"
    )
    coordinator = TunnelCoordinator(
      managerStore: managerStore,
      onTunnelStateChanged: onTunnelStateChanged,
      onConnectionStateChanged: onConnectionStateChanged,
      onExternalStart: onExternalStart,
      onExternalStop: onExternalStop
    )
  }

  deinit {
    if let tunnelStatusObserver {
      NotificationCenter.default.removeObserver(tunnelStatusObserver)
    }
    if let appActiveObserver {
      NotificationCenter.default.removeObserver(appActiveObserver)
    }
    if let appBackgroundObserver {
      NotificationCenter.default.removeObserver(appBackgroundObserver)
    }
    if let appForegroundObserver {
      NotificationCenter.default.removeObserver(appForegroundObserver)
    }
  }

  func startObserving() {
    if tunnelStatusObserver == nil {
      let notificationEpochSource = providerEpoch
      let notificationDirectory = sharedStateStore.appGroupDirectory()
      tunnelStatusObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let notificationEpoch = notificationEpochSource.current()
        let notificationAttempt = RPCSession.readPublished(from: notificationDirectory)?.attempt
        Task { @MainActor in
          guard let self, let connection = notification.object as? NEVPNConnection,
            self.managerStore.isManagedConnection(connection),
            self.coordinator.ownsStatusConnection(connection),
            self.providerEpoch.isCurrent(notificationEpoch),
            RPCSession.readPublished(from: notificationDirectory)?.attempt == notificationAttempt,
            self.observedProviderAttempt == nil || self.observedProviderAttempt == notificationAttempt ||
              (notificationAttempt == nil && (connection.status == .disconnecting || connection.status.isTerminal))
          else { return }
          SwitchDiagnostics.record("tunnel_status", fields: [
            "status": String(connection.status.rawValue),
          ])
          if connection.status == .disconnecting || connection.status.isTerminal {
            self.invalidateProviderRequests()
          }
          self.coordinator.handleTunnelStatusNotification(notification)
        }
      }
    }
    if appActiveObserver == nil {
      appActiveObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.coordinator.requestStatusRefresh(notifyExternal: false)
        }
      }
    }
    if appBackgroundObserver == nil {
      appBackgroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { _ in
        SwitchDiagnostics.record("app_background")
      }
    }
    if appForegroundObserver == nil {
      appForegroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { _ in
        SwitchDiagnostics.record("app_foreground")
      }
    }
    coordinator.requestStatusRefresh(notifyExternal: false)
  }

  func start() {
    SwitchDiagnostics.record("tunnel_start_requested")
    coordinator.submitTunnelRequest(target: .running)
  }

  func publishConnectionState() {
    coordinator.publishConnectionState()
    coordinator.requestStatusRefresh(notifyExternal: false)
  }

  func stop() {
    SwitchDiagnostics.record("tunnel_stop_requested")
    invalidateProviderRequests()
    coordinator.submitTunnelRequest(target: .stopped)
  }

  func toggle() {
    invalidateProviderRequests()
    coordinator.toggleTunnelRequest()
  }

  func reloadOnDemandRules() async throws {
    try await coordinator.reloadOnDemandRules()
  }

  func invalidateProviderRequests() {
    providerEpoch.invalidate()
    configurationGeneration &+= 1
    configurationInFlight = false
  }

  private func synchronizeProviderSession() {
    let attempt = RPCSession.readPublished(from: sharedStateStore.appGroupDirectory())?.attempt
    if attempt != observedProviderAttempt {
      invalidateProviderRequests()
      observedProviderAttempt = attempt
    }
  }

  func captureProviderOwner() -> ProviderOwner {
    synchronizeProviderSession()
    return ProviderOwner(clientEpoch: providerEpoch.current(), attempt: observedProviderAttempt)
  }

  func validateProviderOwner(_ owner: ProviderOwner) throws {
    synchronizeProviderSession()
    guard providerEpoch.isCurrent(owner.clientEpoch), owner.attempt == observedProviderAttempt else {
      throw ProviderMessageError(code: "stale_profile", message: "tunnel attempt changed")
    }
    try Task.checkCancellation()
  }

  @discardableResult
  func beginConfigurationApply() -> UInt64 {
    synchronizeProviderSession()
    configurationGeneration &+= 1
    configurationInFlight = true
    return configurationGeneration
  }

  func finishConfigurationApply(generation: UInt64, success: Bool) {
    guard generation == configurationGeneration else { return }
    configurationInFlight = false
    SwitchDiagnostics.record("configuration_apply_state", fields: [
      "success": String(success),
    ])
  }

  func sendProviderMessage(
    _ data: Data, diagnosticReply: ((String) -> Void)? = nil
  ) async throws -> String {
    let providerOwner = captureProviderOwner()
    let method = SwitchDiagnostics.method(data)
    let retryRead = ProviderReadRetry.isReadOnlyMethod(method)
    if retryRead && configurationInFlight {
      throw ProviderMessageError(
        code: "profile_switching",
        message: "profile switch is still applying"
      )
    }

    let generation = configurationGeneration
    let deadline = Date().addingTimeInterval(retryRead ? providerReadTimeout * Double(ProviderReadRetry.maxAttempts) + 10 : configurationTimeout)
    try await acquireProviderMessageSlot(reserveForConfiguration: retryRead, owner: providerOwner, deadline: deadline,
      configurationGeneration: retryRead ? generation : nil)
    defer { releaseProviderMessageSlot() }
    try validateProviderOwner(providerOwner)
    guard deadline > Date() else {
      throw ProviderMessageError(code: "network_extension_timeout", message: "admission deadline expired")
    }
    let attempts = retryRead ? ProviderReadRetry.maxAttempts : 1
    if isConfigurationMethod(method) {
      sharedStateStore.clearConfigurationRequestApplied()
    }
    let rpcOwner = RPCOwner(attempt: providerOwner.attempt ?? UUID(),
      generation: providerOwner.clientEpoch, nonce: UUID())
    var lastError: ProviderMessageError?

    for attempt in 1...attempts {
      do {
        try validateProviderOwner(providerOwner)
        let response = try await sendProviderMessageAttempt(
          data,
          deadline: min(deadline, Date().addingTimeInterval(retryRead ? providerReadTimeout : configurationTimeout)),
          owner: rpcOwner, clientEpoch: providerOwner.clientEpoch, diagnosticReply: diagnosticReply
        )
        try validateProviderOwner(providerOwner)
        guard Date() < deadline else {
          throw ProviderMessageError(code: "network_extension_timeout", message: "request deadline expired")
        }
        if retryRead &&
          (configurationInFlight || generation != configurationGeneration)
        {
          throw ProviderMessageError(
            code: "stale_profile",
            message: "profile changed while awaiting network extension response"
          )
        }
        return response
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProviderMessageError {
        try validateProviderOwner(providerOwner)
        if !retryRead {
          if isConfigurationMethod(method),
            await waitForAppliedConfiguration(
              SwitchDiagnostics.requestID(data), owner: rpcOwner, providerOwner: providerOwner, deadline: deadline
            )
          {
            return configurationSuccessResponse(data)
          }
          throw error
        }
        lastError = error
        guard ProviderReadRetry.shouldRetry(code: error.code),
          attempt < attempts
        else {
          break
        }
        if error.code == "empty_response_retryable" {
          await refreshManagerAfterNilResponse()
        }
        try await Task.sleep(
          nanoseconds: ProviderReadRetry.backoff(after: attempt)
        )
      }
    }

    SwitchDiagnostics.record("provider_request_failure", fields: [
      "method": method,
      "request_id": SwitchDiagnostics.requestID(data),
      "error_type": lastError?.code ?? "read_retry_exhausted",
    ])
    throw ProviderMessageError(
      code: "network_extension_unavailable",
      message: "network extension is still applying profile"
    )
  }

  #if IOS_ATTEMPT_TESTING
  func testSendAttempt(_ data: Data, deadline: Date) async throws -> String {
    let owner = captureProviderOwner()
    guard let attempt = owner.attempt else {
      throw ProviderMessageError(code: "stale_profile", message: "no attempt")
    }
    return try await sendProviderMessageAttempt(data, deadline: deadline,
      owner: RPCOwner(attempt: attempt, generation: owner.clientEpoch, nonce: UUID()), clientEpoch: owner.clientEpoch)
  }
  #endif

  private func sendProviderMessageAttempt(
    _ data: Data,
    deadline: Date, owner: RPCOwner, clientEpoch: UInt64,
    diagnosticReply: ((String) -> Void)? = nil
  ) async throws -> String {
    let started = ProcessInfo.processInfo.systemUptime
    let requestID = SwitchDiagnostics.requestID(data)
    let method = SwitchDiagnostics.method(data)
    var connection: NEVPNConnection?
    var statusBefore = "unknown"
    func record(_ event: String, responseBytes: Int = 0, errorType: String = "none") {
      SwitchDiagnostics.record(event, fields: [
        "method": method,
        "request_id": requestID,
        "request_bytes": String(data.count),
        "response_bytes": String(responseBytes),
        "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)),
        "status_before": statusBefore,
        "status_after": connection.map { String($0.status.rawValue) } ?? "unknown",
        "error_type": errorType,
      ])
    }

    record("provider_request_begin")
    let manager: NETunnelProviderManager?
    do {
      manager = try await managerStore.loadManager(createIfNeeded: false, deadline: deadline)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      record("provider_request_failure", errorType: "manager_load_failed")
      throw ProviderMessageError(
        code: "network_extension_error",
        message: error.localizedDescription
      )
    }
    try Task.checkCancellation()
    guard providerEpoch.isCurrent(clientEpoch),
      RPCSession.readPublished(from: sharedStateStore.appGroupDirectory())?.attempt == owner.attempt
    else { throw ProviderMessageError(code: "stale_profile", message: "tunnel attempt changed") }
    guard Date() < deadline else {
      throw ProviderMessageError(code: "network_extension_timeout", message: "manager admission deadline expired")
    }
    connection = manager?.connection
    statusBefore = connection.map { String($0.status.rawValue) } ?? "unavailable"
    guard let manager,
      manager.connection.status.tunnelState == .running ||
        (manager.connection.status == .connecting &&
          RPCSession.readPublished(from: sharedStateStore.appGroupDirectory())?.attempt == owner.attempt)
    else {
      record("provider_request_failure", errorType: "network_extension_unavailable")
      throw ProviderMessageError(
        code: "network_extension_unavailable",
        message: "network extension is not running"
      )
    }

    record("provider_request_send")
    do {
      let response = try await providerBridge.send(data, deadline: deadline, owner: owner,
        epoch: providerEpoch, clientEpoch: clientEpoch)
      let errorType = SwitchDiagnostics.responseErrorType(response, method: method)
      record("provider_request_reply", responseBytes: response.utf8.count, errorType: errorType)
      diagnosticReply?(errorType)
      return response
    } catch let error as ProviderMessageError {
      record(
        "provider_request_failure",
        errorType: error.code == "network_extension_timeout"
          ? "network_extension_timeout" : "send_failed"
      )
      throw error
    }
  }

  private func acquireProviderMessageSlot(
    reserveForConfiguration: Bool, owner: ProviderOwner, deadline: Date, configurationGeneration expectedGeneration: UInt64?
  ) async throws {
    let limit = reserveForConfiguration
      ? maxInFlightProviderMessages - 1
      : maxInFlightProviderMessages
    func validateAdmission() throws {
      try validateProviderOwner(owner)
      if let expectedGeneration,
        expectedGeneration != configurationGeneration || configurationInFlight {
        throw ProviderMessageError(code: "stale_profile", message: "profile changed while waiting for slot")
      }
    }
    while inFlightProviderMessages >= limit {
      try validateAdmission()
      guard Date() < deadline else {
        throw ProviderMessageError(code: "network_extension_timeout", message: "admission deadline expired")
      }
      // No continuation may be stranded behind a dead callback. Also observe
      // session replacement/cancellation while every slot is occupied.
      try await Task.sleep(nanoseconds: 40_000_000)
    }
    try validateAdmission()
    inFlightProviderMessages += 1
  }

  private func refreshManagerAfterNilResponse() async {
    if let managerRefreshTask {
      try? await managerRefreshTask.value
      return
    }
    let task = Task { @MainActor in
      try await managerStore.refreshLoadedManager()
    }
    managerRefreshTask = task
    defer { managerRefreshTask = nil }
    do {
      try await task.value
    } catch {
      SwitchDiagnostics.record("core_active_check_failure", fields: [
        "error_type": "manager_load_failed",
      ])
    }
  }

  private func releaseProviderMessageSlot() {
    inFlightProviderMessages = max(0, inFlightProviderMessages - 1)
  }

  private func waitForAppliedConfiguration(_ requestID: String?, owner: RPCOwner,
    providerOwner: ProviderOwner, deadline: Date) async -> Bool {
    guard let requestID else { return false }
    for _ in 0..<5 {
      guard Date() < deadline, (try? validateProviderOwner(providerOwner)) != nil else { return false }
      if sharedStateStore.isConfigurationRequestApplied(requestID, owner: owner) {
        return true
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard Date() < deadline, (try? validateProviderOwner(providerOwner)) != nil else { return false }
    return sharedStateStore.isConfigurationRequestApplied(requestID, owner: owner)
  }

  private func isConfigurationMethod(_ method: String) -> Bool {
    method == "setupConfig" || method == "updateConfig"
  }

  private func methodCallID(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any]
    else {
      return nil
    }
    return object["id"] as? String
  }

  private func configurationSuccessResponse(_ data: Data) -> String {
    var payload: [String: Any] = [
      "result": "",
      "error": NSNull(),
    ]
    if let id = methodCallID(data) {
      payload["id"] = id
    }
    guard let response = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: response, encoding: .utf8)
    else {
      return #"{"result":"","error":null}"#
    }
    return text
  }

  func isCoreActive() async -> Bool {
    do {
      let manager = try await managerStore.loadManager(createIfNeeded: false)
      return manager?.connection.status.tunnelState == .running
    } catch {
      SwitchDiagnostics.record("core_active_check_failure", fields: [
        "error_type": "manager_load_failed",
      ])
      return false
    }
  }

  func getRunTime() async -> Int {
    guard await isCoreActive() else {
      return 0
    }
    return sharedStateStore.runTime()
  }
}

/// App-side transport for control-plane requests to the Network Extension.
///
/// Replaces `NETunnelProviderSession.sendProviderMessage`, which can silently
/// drop the message before it reaches the extension on some sideload/resign
/// configurations. Each request is written to the shared App Group container
/// and the extension writes the response back to the same container, so the
/// control plane no longer depends on the fragile provider message port.
actor ProviderMessageBridge {
  private let appGroupIdentifier: String
  private let commandNotificationName: String
  private let directoryName = "core-rpc"
  private let requestExtension = "req"
  private let responseExtension = "resp"
  private let pollIntervalNanoseconds: UInt64 = 40_000_000
  private let maxOrphanAge: TimeInterval = 180

  init(
    appGroupIdentifier: String,
    commandNotificationName: String
  ) {
    self.appGroupIdentifier = appGroupIdentifier
    self.commandNotificationName = commandNotificationName
  }

  func send(_ data: Data, deadline: Date, owner: RPCOwner,
    epoch: RPCClientEpoch, clientEpoch: UInt64) async throws -> String {
    let id = UUID().uuidString
    guard Date() < deadline else {
      throw ProviderMessageError(code: "network_extension_timeout", message: "admission deadline expired")
    }
    let request = RPCRequest(version: RPCWire.version, owner: owner,
      deadline: deadline, data: data)
    func validate() throws {
      try Task.checkCancellation()
      guard Date() < deadline else {
        throw ProviderMessageError(code: "network_extension_timeout", message: "request deadline expired")
      }
      guard epoch.isCurrent(clientEpoch),
        let session = RPCSession.readPublished(from: rpcDirectory()?.deletingLastPathComponent()),
        session.attempt == request.owner.attempt
      else { throw ProviderMessageError(code: "stale_profile", message: "tunnel attempt changed") }
    }
    try validate()
    // Legitimate work admitted during this same cold-start attempt waits for
    // ready; never retag a request with a later attempt just to make it execute.
    while RPCSession.read(from: rpcDirectory()?.deletingLastPathComponent()) == nil {
      try validate()
      guard Date() < request.deadline else {
        throw ProviderMessageError(code: "network_extension_timeout", message: "tunnel not ready")
      }
      try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    try validate()
    pruneOrphans()
    guard writeRequest(id: id, data: try JSONEncoder().encode(request), validate: validate) else {
      throw ProviderMessageError(
        code: "network_extension_error",
        message: "failed to enqueue network extension request"
      )
    }
    defer { cleanup(id: id) }
    postCommandNotification()
    repeat {
      try validate()
      let method = SwitchDiagnostics.method(request.data)
      if method == "setupConfig" || method == "updateConfig",
        SharedStateStore().isConfigurationRequestApplied(SwitchDiagnostics.requestID(request.data), owner: request.owner) {
        try validate()
        var payload: [String: Any] = ["result": "", "error": NSNull()]
        if let object = try? JSONSerialization.jsonObject(with: request.data) as? [String: Any],
          let id = object["id"] as? String { payload["id"] = id }
        let receiptResponse = try JSONSerialization.data(withJSONObject: payload)
        try validate()
        return String(decoding: receiptResponse, as: UTF8.self)
      }
      if let response = readResponse(id: id),
        let bytes = response.data(using: .utf8),
        let reply = try? JSONDecoder().decode(RPCReply.self, from: bytes),
        reply.version == RPCWire.version, reply.owner == request.owner {
        try validate()
        guard let text = String(data: reply.data, encoding: .utf8) else {
          throw ProviderMessageError(code: "invalid_utf8", message: "invalid response encoding")
        }
        try validate()
        return text
      }
      try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    } while Date() < request.deadline
    throw ProviderMessageError(
      code: "network_extension_timeout",
      message: "network extension response timed out"
    )
  }

  private func writeRequest(id: String, data: Data, validate: () throws -> Void) -> Bool {
    guard let directory = requestDirectory() else { return false }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let destination = directory
        .appendingPathComponent("\(id).\(requestExtension)")
      let temporary = directory.appendingPathComponent(".\(id).tmp")
      defer { try? FileManager.default.removeItem(at: temporary) }
      try data.write(to: temporary)
      try validate() // absolute budget/owner immediately before atomic admission
      try FileManager.default.moveItem(at: temporary, to: destination)
      return true
    } catch {
      return false
    }
  }

  private func readResponse(id: String) -> String? {
    guard let directory = responseDirectory() else { return nil }
    let fileURL = directory
      .appendingPathComponent("\(id).\(responseExtension)")
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private func cleanup(id: String) {
    if let requestDirectory = requestDirectory() {
      try? FileManager.default.removeItem(
        at: requestDirectory.appendingPathComponent("\(id).\(requestExtension)")
      )
    }
    if let responseDirectory = responseDirectory() {
      try? FileManager.default.removeItem(
        at: responseDirectory.appendingPathComponent("\(id).\(responseExtension)")
      )
    }
  }

  private func pruneOrphans() {
    let cutoff = Date().addingTimeInterval(-maxOrphanAge)
    for directory in [requestDirectory(), responseDirectory()].compactMap({ $0 }) {
      guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey]
      ) else {
        continue
      }
      for fileURL in files {
        let modified = (try? fileURL.resourceValues(
          forKeys: [.contentModificationDateKey]
        ))?.contentModificationDate
        if let modified, modified < cutoff {
          try? FileManager.default.removeItem(at: fileURL)
        }
      }
    }
  }

  #if IOS_ATTEMPT_TESTING
  static var testDirectory: URL?
  static func setTestRoot(_ root: URL) { testDirectory = root }
  #endif

  private func rpcDirectory() -> URL? {
    #if IOS_ATTEMPT_TESTING
    if let root = Self.testDirectory { return root.appendingPathComponent(directoryName, isDirectory: true) }
    #endif
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )?.appendingPathComponent(directoryName, isDirectory: true)
  }

  private func requestDirectory() -> URL? {
    rpcDirectory()?.appendingPathComponent("req", isDirectory: true)
  }

  private func responseDirectory() -> URL? {
    rpcDirectory()?.appendingPathComponent("resp", isDirectory: true)
  }

  private func postCommandNotification() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(commandNotificationName as CFString),
      nil,
      nil,
      true
    )
  }
}
