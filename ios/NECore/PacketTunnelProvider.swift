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

  private var suspendSupport = true
  private let resourceHeartbeat = NativeResourceHeartbeat()

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    NECoreSideloadCompatibilityLoader.loadIfPresent()
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
      "startTunnel options stack=\(vpnOptions.stack, privacy: .public) ipv6=\(vpnOptions.ipv6, privacy: .public) captureDns=\(vpnOptions.captureDns, privacy: .public) systemProxy=\(vpnOptions.systemProxy, privacy: .public) suspendSupport=\(vpnOptions.suspendSupport, privacy: .public)"
    )
    let setupParamsData = sharedStateStore.loadSetupParams()
    diag(
      "vpn_options stack=\(vpnOptions.stack) ipv6=\(vpnOptions.ipv6) captureDns=\(vpnOptions.captureDns) systemProxy=\(vpnOptions.systemProxy) mtu=\(vpnOptions.mtu) routeCount=\(vpnOptions.routeAddress.count)"
    )
    diag(
      "setup_params bytes=\(setupParamsData.count) empty=\(setupParamsData.count <= 2)"
    )
    suspendSupport = vpnOptions.suspendSupport

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
    logger.debug(
      "handleAppMessage bytes=\(messageData.count, privacy: .public)"
    )
    eventQueue.markCoreResponsive()
    guard let completionHandler else {
      logger.warning("handleAppMessage ignored: missing completion handler")
      return
    }

    NECoreBridge.invokeMethod(messageData) { response in
      guard let response else {
        self.logger.warning("handleAppMessage empty core response")
        completionHandler(
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
      completionHandler(response)
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    if suspendSupport {
      logger.info("sleep: suspending tunnel")
      NECoreBridge.setSuspended(true)
    }
    completionHandler()
  }

  override func wake() {
    if suspendSupport {
      logger.info("wake: resuming tunnel")
      NECoreBridge.setSuspended(false)
    }
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
