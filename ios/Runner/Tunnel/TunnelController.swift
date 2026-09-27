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

  func sendProviderMessage(_ data: Data) async throws -> String {
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
      do {
        try session.sendProviderMessage(data) { response in
          Task { @MainActor in
            record("provider_request_reply", responseBytes: response?.count ?? 0,
              errorType: response == nil ? "nil_response" : "none")
            guard let response else {
              record("provider_request_failure", errorType: "nil_response")
              continuation.resume(
                throwing: ProviderMessageError(
                  code: "empty_response",
                  message: "empty network extension response"
                )
              )
              return
            }
            guard let message = String(data: response, encoding: .utf8) else {
              record("provider_request_failure", responseBytes: response.count,
                errorType: "invalid_utf8")
              continuation.resume(
                throwing: ProviderMessageError(
                  code: "empty_response",
                  message: "empty network extension response"
                )
              )
              return
            }
            continuation.resume(returning: message)
          }
        }
      } catch {
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
