import Foundation
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
  private var providerMessageWaiters: [CheckedContinuation<Void, Never>] = []
  private var configurationGeneration: UInt64 = 0
  private var configurationInFlight = false
  private var managerRefreshTask: Task<Void, Error>?
  private let providerBridge: ProviderMessageBridge

  init(
    sharedStateStore: SharedStateStore,
    onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
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
      tunnelStatusObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor in
          SwitchDiagnostics.record("tunnel_status", fields: [
            "status": (notification.object as? NEVPNConnection).map { String($0.status.rawValue) } ?? "unknown",
          ])
          self?.coordinator.handleTunnelStatusNotification(notification)
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

  func stop() {
    SwitchDiagnostics.record("tunnel_stop_requested")
    coordinator.submitTunnelRequest(target: .stopped)
  }

  func toggle(notifyExternal: Bool) {
    coordinator.toggleTunnelRequest(
      notifyExternalOnCompletion: notifyExternal
    )
  }

  func reloadOnDemandRules() async throws {
    try await coordinator.reloadOnDemandRules()
  }

  @discardableResult
  func beginConfigurationApply() -> UInt64 {
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

  func sendProviderMessage(_ data: Data) async throws -> String {
    let method = SwitchDiagnostics.method(data)
    let retryRead = ProviderReadRetry.isReadOnlyMethod(method)
    if retryRead && configurationInFlight {
      throw ProviderMessageError(
        code: "profile_switching",
        message: "profile switch is still applying"
      )
    }

    await acquireProviderMessageSlot(reserveForConfiguration: retryRead)
    defer { releaseProviderMessageSlot() }
    let generation = configurationGeneration
    let attempts = retryRead ? ProviderReadRetry.maxAttempts : 1
    if isConfigurationMethod(method) {
      sharedStateStore.clearConfigurationRequestApplied()
    }
    var lastError: ProviderMessageError?

    for attempt in 1...attempts {
      do {
        let response = try await sendProviderMessageAttempt(
          data,
          timeout: retryRead ? providerReadTimeout : configurationTimeout
        )
        if retryRead &&
          (configurationInFlight || generation != configurationGeneration)
        {
          throw ProviderMessageError(
            code: "stale_profile",
            message: "profile changed while awaiting network extension response"
          )
        }
        return response
      } catch let error as ProviderMessageError {
        if !retryRead {
          if isConfigurationMethod(method),
            await waitForAppliedConfiguration(
              SwitchDiagnostics.requestID(data)
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
        try? await Task.sleep(
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

  private func sendProviderMessageAttempt(
    _ data: Data,
    timeout: TimeInterval
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
      manager = try await managerStore.loadManager(createIfNeeded: false)
    } catch {
      record("provider_request_failure", errorType: "manager_load_failed")
      throw ProviderMessageError(
        code: "network_extension_error",
        message: error.localizedDescription
      )
    }
    connection = manager?.connection
    statusBefore = connection.map { String($0.status.rawValue) } ?? "unavailable"
    guard let manager,
      manager.connection.status.tunnelState == .running
    else {
      record("provider_request_failure", errorType: "network_extension_unavailable")
      throw ProviderMessageError(
        code: "network_extension_unavailable",
        message: "network extension is not running"
      )
    }

    record("provider_request_send")
    do {
      let response = try await providerBridge.send(data, timeout: timeout)
      record("provider_request_reply", responseBytes: response.utf8.count)
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
    reserveForConfiguration: Bool
  ) async {
    let limit = reserveForConfiguration
      ? maxInFlightProviderMessages - 1
      : maxInFlightProviderMessages
    while inFlightProviderMessages >= limit {
      await withCheckedContinuation { continuation in
        providerMessageWaiters.append(continuation)
      }
    }
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
    guard !providerMessageWaiters.isEmpty else { return }
    providerMessageWaiters.removeFirst().resume()
  }

  private func waitForAppliedConfiguration(_ requestID: String?) async -> Bool {
    guard let requestID else { return false }
    for _ in 0..<5 {
      if sharedStateStore.isConfigurationRequestApplied(requestID) {
        return true
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return sharedStateStore.isConfigurationRequestApplied(requestID)
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

  func send(_ data: Data, timeout: TimeInterval) async throws -> String {
    let id = UUID().uuidString
    pruneOrphans()
    guard writeRequest(id: id, data: data) else {
      throw ProviderMessageError(
        code: "network_extension_error",
        message: "failed to enqueue network extension request"
      )
    }
    defer { cleanup(id: id) }
    postCommandNotification()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let response = readResponse(id: id) {
        return response
      }
      try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    } while Date() < deadline
    throw ProviderMessageError(
      code: "network_extension_timeout",
      message: "network extension response timed out"
    )
  }

  private func writeRequest(id: String, data: Data) -> Bool {
    guard let directory = requestDirectory() else { return false }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let destination = directory
        .appendingPathComponent("\(id).\(requestExtension)")
      let temporary = directory.appendingPathComponent(".\(id).tmp")
      try data.write(to: temporary)
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

  private func rpcDirectory() -> URL? {
    FileManager.default.containerURL(
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
