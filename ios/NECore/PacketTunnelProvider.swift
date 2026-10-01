import Darwin
import Foundation
import NetworkExtension
import WidgetKit
import os

private enum NECoreSideloadCompatibilityLoader {
  private static var handle: UnsafeMutableRawPointer?

  static func loadIfPresent() {
    guard handle == nil,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else { return }
    let dylibURL = frameworksURL.appendingPathComponent(
      "Tg_@HelloWorld_1024.dylib"
    )
    guard FileManager.default.fileExists(atPath: dylibURL.path) else { return }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let sharedStateStore = PacketTunnelSharedStateStore()
  private let networkConfiguration = PacketTunnelNetworkConfiguration()
  private lazy var eventQueue = NECoreEventQueue(
    sharedStateStore: sharedStateStore
  )
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "PacketTunnelProvider"
  )

  private let resourceHeartbeat = NativeResourceHeartbeat()
  private var memoryPressureSource: DispatchSourceMemoryPressure?

  private func startMemoryPressureDiagnostics() {
    memoryPressureSource?.cancel()
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: DispatchQueue(label: "com.follow.clash.memory-pressure-diagnostics")
    )
    source.setEventHandler { [weak self] in
      guard let source = self?.memoryPressureSource else { return }
      SwitchDiagnostics.record("os_memory_pressure", fields: ["status": String(source.data.rawValue)])
    }
    memoryPressureSource = source
    source.resume()
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    NECoreSideloadCompatibilityLoader.loadIfPresent()
    SwitchDiagnostics.record("tunnel_start", fields: ["attempt_id": SwitchDiagnostics.processID])
    startMemoryPressureDiagnostics()
    let originalCompletion = completionHandler
    let completionHandler: (Error?) -> Void = { error in
      SwitchDiagnostics.record("tunnel_start_complete", fields: ["success": String(error == nil)])
      originalCompletion(error)
    }
    logger.info("startTunnel begin")
    diag("startup begin")
    diag(configProbe())
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    guard let vpnOptions = sharedStateStore.loadVPNOptions() else {
      logger.error("startTunnel failed: missing vpn options")
      diag("startup_failure phase=vpn_options_missing")
      completionHandler(PacketTunnelProviderError.missingVPNOptions)
      return
    }
    logger.info(
      "startTunnel options stack=\(vpnOptions.stack, privacy: .public) ipv6=\(vpnOptions.ipv6, privacy: .public) captureDns=\(vpnOptions.captureDns, privacy: .public) systemProxy=\(vpnOptions.systemProxy, privacy: .public)"
    )
    let setupParamsData = sharedStateStore.loadSetupParams()
    diag(
      "vpn_options stack=\(vpnOptions.stack) ipv6=\(vpnOptions.ipv6) captureDns=\(vpnOptions.captureDns) systemProxy=\(vpnOptions.systemProxy) mtu=\(vpnOptions.mtu) routeCount=\(vpnOptions.routeAddress.count)"
    )
    diag(
      "setup_params bytes=\(setupParamsData.count) empty=\(setupParamsData.count <= 2)"
    )

    setTunnelNetworkSettings(
      networkConfiguration.makeSettings(for: vpnOptions)
    ) { error in
      if let error {
        self.logger.error(
          "setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)"
        )
        self.diag("startup_failure phase=set_network_settings error=\(error.localizedDescription)")
        completionHandler(error)
        return
      }
      self.logger.info("setTunnelNetworkSettings completed")
      self.diag("set_network_settings ok")
      guard let tunnelFileDescriptor =
        self.networkConfiguration.tunnelFileDescriptor()
      else {
        self.logger.error(
          "startTunnel failed: tunnel file descriptor missing"
        )
        self.diag("startup_failure phase=tunnel_fd_missing")
        completionHandler(
          PacketTunnelProviderError.couldNotDetermineFileDescriptor
        )
        return
      }
      self.logger.debug(
        "startTunnel fileDescriptor=\(tunnelFileDescriptor, privacy: .public)"
      )
      self.diag("tunnel_fd=\(tunnelFileDescriptor)")
      self.eventQueue.start()
      self.diag(
        "mem_before_quick_setup footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
      )
      NativeDiagnosticLog.shared.flush()
      // Start sampling before the config load so a jetsam kill while the core
      // builds rule-provider matchers leaves a footprint trail instead of silence.
      self.resourceHeartbeat.start()
      let initParams = self.sharedStateStore.makeInitParams()
      let setupParams = self.sharedStateStore.loadSetupParams()
      self.logger.info(
        "quickSetup initParams=\(initParams, privacy: .public)"
      )
      NECoreBridge.quickSetup(
        withInitParams: initParams,
        setupParams: setupParams
      ) { result in
        if let result,
          !result.isEmpty
        {
          let message = String(data: result, encoding: .utf8) ??
            "unknown core error"
          self.logger.error(
            "quickSetup failed: \(message, privacy: .public)"
          )
          self.diag("startup_failure phase=quick_setup error=\(message)")
          completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
          return
        }
        self.logger.info("quickSetup completed")
        self.diag(
          "quick_setup ok footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
        )
        NativeDiagnosticLog.shared.flush()
        let coreTunOptions = CoreTunOptions(
          stack: vpnOptions.stack,
          address: self.networkConfiguration.tunAddress(for: vpnOptions),
          dns: self.networkConfiguration.tunDNS(for: vpnOptions),
          mtu: vpnOptions.mtu,
          disableIcmpForwarding: vpnOptions.disableIcmpForwarding,
          endpointIndependentNat: vpnOptions.endpointIndependentNat,
          congestionController: vpnOptions.congestionController,
          recvMsgX: vpnOptions.recvMsgX,
          sendMsgX: vpnOptions.sendMsgX
        )
        guard let coreTunOptionsData = try? JSONEncoder().encode(coreTunOptions)
        else {
          self.diag("startup_failure phase=tun_options_encode")
          NativeDiagnosticLog.shared.flush()
          completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
          return
        }
        self.diag(
          "tun_start begin footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
        )
        NativeDiagnosticLog.shared.flush()
        let started = NECoreBridge.startTun(
          withFileDescriptor: tunnelFileDescriptor,
          options: coreTunOptionsData
        )
        self.logger.info(
          "NECoreBridge.startTun result=\(started, privacy: .public)"
        )
        self.diag(
          "start_tun result=\(started) footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
        )
        NativeDiagnosticLog.shared.flush()
        if started {
          self.sharedStateStore.saveRunTime()
        } else {
          self.resourceHeartbeat.stop()
        }
        completionHandler(
          started ? nil : PacketTunnelProviderError.couldNotStartCoreTun
        )
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    SwitchDiagnostics.record("tunnel_stop", fields: ["reason": String(reason.rawValue)])
    memoryPressureSource?.cancel()
    memoryPressureSource = nil
    logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    eventQueue.stop()
    resourceHeartbeat.stop()
    NECoreBridge.stopTun()
    guard reason == .userInitiated else {
      completionHandler()
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error {
        self.logger.error(
          "stopTunnel loadAllFromPreferences error=\(error.localizedDescription, privacy: .public)"
        )
        completionHandler()
        return
      }
      guard let manager = managers?.first(where: { manager in
        guard let proto = manager.protocolConfiguration
          as? NETunnelProviderProtocol
        else {
          return false
        }
        return proto.providerBundleIdentifier ==
          PacketTunnelEnvironment.extensionBundleIdentifier
      }) else {
        completionHandler()
        return
      }
      manager.isOnDemandEnabled = false
      manager.saveToPreferences { error in
        if let error {
          self.logger.error(
            "stopTunnel saveToPreferences error=\(error.localizedDescription, privacy: .public)"
          )
        }
        completionHandler()
      }
    }
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    let receivedAt = ProcessInfo.processInfo.systemUptime
    let requestID = SwitchDiagnostics.requestID(messageData)
    let method = SwitchDiagnostics.method(messageData)
    SwitchDiagnostics.record("rpc_received", fields: [
      "request_id": requestID, "method": method, "request_bytes": String(messageData.count),
    ])
    if method == "setupConfig" || method == "updateConfig" {
      _ = configProbe()
      sharedStateStore.clearConfigurationRequestApplied()
    }
    logger.debug(
      "handleAppMessage bytes=\(messageData.count, privacy: .public)"
    )
    eventQueue.markCoreResponsive()
    guard let completionHandler else {
      SwitchDiagnostics.record("rpc_missing_completion", fields: ["request_id": requestID, "method": method])
      logger.warning("handleAppMessage ignored: missing completion handler")
      return
    }
    let reply: (Data?) -> Void = { response in
      SwitchDiagnostics.record("rpc_reply", fields: [
        "request_id": requestID, "method": method,
        "response_bytes": String(response?.count ?? 0),
        "status": response == nil ? "nil_response" : "response",
        "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - receivedAt) * 1000)),
      ])
      completionHandler(response)
    }

    NECoreBridge.invokeMethod(messageData) { response in
      guard let response else {
        SwitchDiagnostics.record("rpc_core_empty", fields: ["request_id": requestID, "method": method])
        self.logger.warning("handleAppMessage empty core response")
        reply(
          self.methodErrorResponse(
            messageData: messageData,
            code: "empty_response",
            message: "empty core response"
          )
        )
        return
      }
      self.logger.debug(
        "handleAppMessage response bytes=\(response.count, privacy: .public)"
      )
      if (method == "setupConfig" || method == "updateConfig"),
        self.methodResponseHasEmptyStringResult(response)
      {
        self.sharedStateStore.markConfigurationRequestApplied(requestID)
      }
      reply(response)
    }
  }

  private func methodResponseHasEmptyStringResult(_ response: Data) -> Bool {
    guard let payload = try? JSONSerialization.jsonObject(with: response)
      as? [String: Any],
      payload["error"] == nil || payload["error"] is NSNull
    else {
      return false
    }
    return payload["result"] as? String == ""
  }

  private func methodErrorResponse(
    messageData: Data,
    code: String,
    message: String
  ) -> Data? {
    var payload: [String: Any] = [
      "result": NSNull(),
      "error": [
        "code": code,
        "message": message,
        "details": NSNull(),
      ],
    ]
    if let id = methodCallID(messageData) {
      payload["id"] = id
    }
    return try? JSONSerialization.data(withJSONObject: payload)
  }

  private func methodCallID(_ messageData: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: messageData)
      as? [String: Any]
    else {
      return nil
    }
    return object["id"] as? String
  }

  private func reloadControlWidget() {
    if #available(iOS 18.0, *) {
      ControlCenter.shared.reloadControls(
        ofKind: PacketTunnelEnvironment.widgetIdentifier
      )
    }
  }

  private func diag(_ message: String) {
    NativeDiagnosticLog.shared.append(message)
  }

  private func configProbe() -> String {
    guard let directory = sharedStateStore.appGroupDirectory() else {
      return "config_probe home_dir=missing"
    }
    let configURL = directory.appendingPathComponent("config.yaml")
    let exists = FileManager.default.fileExists(atPath: configURL.path)
    var bytes = 0
    var proxyNameLines = -1
    if exists, let data = try? Data(contentsOf: configURL) {
      SwitchDiagnostics.record("config_snapshot", fields: [
        "profile_digest": SwitchDiagnostics.requestID(data), "request_bytes": String(data.count),
      ])
      bytes = data.count
      if let text = String(data: data, encoding: .utf8) {
        proxyNameLines = text
          .split(separator: "\n")
          .filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- name:")
          }
          .count
      }
    }
    return "config_probe configExists=\(exists) configBytes=\(bytes) proxyNameLines=\(proxyNameLines)"
  }
}

private struct CoreTunOptions: Encodable {
  let stack: String
  let address: String
  let dns: String
  let mtu: Int
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
  let congestionController: String
  let recvMsgX: Bool
  let sendMsgX: Bool
}

private enum PacketTunnelProviderError: LocalizedError {
  case missingVPNOptions
  case couldNotDetermineFileDescriptor
  case couldNotStartCoreTun

  var errorDescription: String? {
    switch self {
    case .missingVPNOptions:
      return "missing VPN options"
    case .couldNotDetermineFileDescriptor:
      return "could not determine tunnel file descriptor"
    case .couldNotStartCoreTun:
      return "could not start core TUN"
    }
  }
}
