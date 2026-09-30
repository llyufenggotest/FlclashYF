import Foundation
import NetworkExtension
import UIKit

@MainActor
final class TunnelController {
  private final class ProviderMessageWaiter {
    private var finished = false

    func finish(_ action: () -> Void) {
      guard !finished else { return }
      finished = true
      action()
    }
  }

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

    await acquireProviderMessageSlot()
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
      manager.connection.status.tunnelState == .running,
      let session = manager.connection as? NETunnelProviderSession
    else {
      record("provider_request_failure", errorType: "network_extension_unavailable")
      throw ProviderMessageError(
        code: "network_extension_unavailable",
        message: "network extension is not running"
      )
    }

    record("provider_request_send")
    return try await withCheckedThrowingContinuation { continuation in
      let waiter = ProviderMessageWaiter()
      let timeoutWork = DispatchWorkItem {
        waiter.finish {
          record("provider_request_failure", errorType: "network_extension_timeout")
          continuation.resume(
            throwing: ProviderMessageError(
              code: "network_extension_timeout",
              message: "network extension response timed out"
            )
          )
        }
      }
      DispatchQueue.main.asyncAfter(
        deadline: .now() + timeout,
        execute: timeoutWork
      )
      do {
        try session.sendProviderMessage(data) { response in
          Task { @MainActor in
            waiter.finish {
              timeoutWork.cancel()
              record(
                "provider_request_reply",
                responseBytes: response?.count ?? 0,
                errorType: response == nil ? "nil_response" : "none"
              )
              guard let response else {
                continuation.resume(
                  throwing: ProviderMessageError(
                    code: manager.connection.status.tunnelState == .running
                      ? "empty_response_retryable"
                      : "network_extension_unavailable",
                    message: "empty network extension response"
                  )
                )
                return
              }
              guard let message = String(data: response, encoding: .utf8) else {
                continuation.resume(
                  throwing: ProviderMessageError(
                    code: "empty_response",
                    message: "invalid network extension response"
                  )
                )
                return
              }
              continuation.resume(returning: message)
            }
          }
        }
      } catch {
        waiter.finish {
          timeoutWork.cancel()
          record("provider_request_failure", errorType: "send_failed")
          continuation.resume(
            throwing: ProviderMessageError(
              code: "network_extension_error",
              message: error.localizedDescription
            )
          )
        }
      }
    }
  }

  private func acquireProviderMessageSlot() async {
    while inFlightProviderMessages >= maxInFlightProviderMessages {
      await withCheckedContinuation { continuation in
        providerMessageWaiters.append(continuation)
      }
    }
    inFlightProviderMessages += 1
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
