import Darwin
import Foundation
import NetworkExtension
import WidgetKit
import os

private let SwitchDiagnosticProviderCodes = ["rpc_publication": 1, "vpn_options": 2, "network_settings": 3, "tunnel_fd": 4, "quick_setup": 5, "start_tun": 6, "command_server": 7, "cancelled": 8, "completion": 9]
// IPadDiagnosticFailure is a fixed diagnostic classification, not a new retry policy.
private enum NECoreSideloadCompatibilityLoader {
  private static var handle: UnsafeMutableRawPointer?

  static func loadIfPresent() {
    SwitchDiagnostics.record("ipad_loader_before")
    defer { SwitchDiagnostics.record("ipad_loader_after", fields: ["loader_loaded": String(handle != nil)]) }
    guard handle == nil,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else { return }
    let dylibURL = frameworksURL.appendingPathComponent(
      "Tg_@HelloWorld_1024.dylib"
    )
    let exists = FileManager.default.fileExists(atPath: dylibURL.path)
    SwitchDiagnostics.record("ipad_loader_before", fields: ["loader_exists": String(exists)])
    guard exists else { return }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let sharedStateStore = PacketTunnelSharedStateStore()
  private let networkConfiguration = PacketTunnelNetworkConfiguration()
  private lazy var eventQueue = NECoreEventQueue(
    sharedStateStore: sharedStateStore
  )
  private lazy var commandServer = PacketTunnelCommandServer(
    sharedStateStore: sharedStateStore,
    invoke: { data, completion in
      NECoreBridge.invokeMethod(data) { response in
        completion(response)
      }
    }
  )
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "PacketTunnelProvider"
  )


  private let resourceHeartbeat = NativeResourceHeartbeat()
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var eventQueueStarted = false
  private var commandServerStarted = false
  // Main-queue owned, retained after success until stop/failure.
  private var activeCleanup: PacketTunnelLifecycleCleanup?
  private var pendingStartupCompletion: ((Error?) -> Void)?
  // Native quickSetup has no cancellation API. Do not overlap another attempt
  // with an old setup still mutating the process-global core after stop.
  private var coreSetupOwner: PacketTunnelLifecycleCleanup?
  private var lifecycleGeneration = UUID()
  private var activeAttempt: UUID?
  private var coreReclaimRetiring = false
  private var diagnosticStage = "completion"
  override init() {
    super.init()
    SwitchDiagnostics.record("ipad_provider_init")
  }
  // Stable OS bridge channel, independent of the possibly broken App Group.
  private func diagnosticError(_ original: Error) -> NSError {
    let code = SwitchDiagnosticProviderCodes[diagnosticStage] ?? 9
    return NSError(domain: "com.flclashyf.iPadDiagnostic", code: code,
      userInfo: [NSUnderlyingErrorKey: original])
  }

  private func stopMemoryPressureDiagnostics() {
    memoryPressureSource?.cancel()
    memoryPressureSource = nil
  }

  private func startMemoryPressureDiagnostics() {
    stopMemoryPressureDiagnostics()
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: DispatchQueue(label: "com.follow.clash.memory-pressure-diagnostics")
    )
    source.setEventHandler { [weak self] in
      DispatchQueue.main.async {
        guard let source = self?.memoryPressureSource else { return }
        SwitchDiagnostics.record("os_memory_pressure", fields: ["status": String(source.data.rawValue)])
      }
    }
    memoryPressureSource = source
    source.resume()
  }

  private func makeLifecycleCleanup(ownedAttempt: UUID) -> PacketTunnelLifecycleCleanup {
    PacketTunnelLifecycleCleanup(actions: [{ [weak self] in
      guard let self, self.activeAttempt == ownedAttempt else { return }
      SwitchDiagnostics.record("ipad_cleanup", fields: ["attempt_id": ownedAttempt.uuidString])
      self.activeAttempt = nil
      if RPCSession.readPublished(from: self.sharedStateStore.appGroupDirectory())?.attempt == ownedAttempt {
        RPCSession(version: RPCWire.version, attempt: ownedAttempt, ready: false, retired: true)
          .publish(to: self.sharedStateStore.appGroupDirectory())
      }
      self.stopMemoryPressureDiagnostics()
      if self.eventQueueStarted {
        self.eventQueue.stop()
        self.eventQueueStarted = false
      }
      self.coreReclaimRetiring = true
      self.resourceHeartbeat.retire { [weak self] in
        // Old uncancellable GC must exit before native shutdown; a deadline
        // completing the OS request never retires this core owner early.
        NECoreBridge.stopTun()
        DispatchQueue.main.async { self?.coreReclaimRetiring = false }
      }
      if self.commandServerStarted {
        self.commandServer.stop()
        self.commandServerStarted = false
      }
    }])
  }

  #if IOS_ATTEMPT_TESTING
  // Expose only the captured production cleanup action to native race probes.
  func testCapturedCleanup() -> PacketTunnelLifecycleCleanup? { activeCleanup }
  #endif

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.startTunnel(options: options, completionHandler: completionHandler)
      }
      return
    }
    guard activeCleanup == nil, coreSetupOwner == nil, !coreReclaimRetiring else {
      completionHandler(NSError(domain: "com.flclashyf.iPadDiagnostic", code: 9, userInfo: [NSUnderlyingErrorKey: PacketTunnelProviderError.couldNotStartCoreTun]))
      return
    }
    SwitchDiagnostics.record("ipad_provider_entry")
    diagnosticStage = "completion"
    NECoreSideloadCompatibilityLoader.loadIfPresent()
    SwitchDiagnostics.record("tunnel_start", fields: ["attempt_id": SwitchDiagnostics.processID])
    startMemoryPressureDiagnostics()
    lifecycleGeneration = UUID()
    let ownedAttempt = lifecycleGeneration
    activeAttempt = ownedAttempt
    let cleanup = makeLifecycleCleanup(ownedAttempt: ownedAttempt)
    activeCleanup = cleanup
    pendingStartupCompletion = completionHandler
    let completionHandler: (Error?) -> Void = { error in
      guard self.activeCleanup === cleanup else { return }
      guard let originalCompletion = self.pendingStartupCompletion else { return }
      self.pendingStartupCompletion = nil
      if error != nil {
        cleanup.cleanup()
        self.activeCleanup = nil
      }
      SwitchDiagnostics.record("tunnel_start_complete", fields: ["success": String(error == nil)])
      SwitchDiagnostics.record("ipad_completion", fields: ["success": String(error == nil), "attempt_id": ownedAttempt.uuidString])
      if let error { originalCompletion(self.diagnosticError(error)) } else { originalCompletion(nil) }
    }
    // Publication is admission, not a best-effort diagnostic. Fail before any
    // asynchronous setup if an old ready record could not be withdrawn.
    diagnosticStage = "rpc_publication"
    SwitchDiagnostics.record("ipad_rpc_publication", fields: ["attempt_id": ownedAttempt.uuidString])
    guard RPCSession(version: RPCWire.version, attempt: lifecycleGeneration, ready: false)
      .publish(to: sharedStateStore.appGroupDirectory()) else {
      // If atomic replacement failed (e.g. ENOSPC), unlink the prior ready
      // record as well. No new asynchronous attempt can exist at this point.
      if let root = sharedStateStore.appGroupDirectory() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("core-rpc/session.json"))
      }
      completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
      return
    }
    logger.info("startTunnel begin")
    diag("startup begin")
    diag(configProbe())
    sharedStateStore.clearRunTime()
    reloadWidgets()
    diagnosticStage = "vpn_options"
    SwitchDiagnostics.record("ipad_vpn_options", fields: ["attempt_id": ownedAttempt.uuidString])
    guard let snapshot = sharedStateStore.loadVPNOptionsSnapshot() else {
      logger.error("startTunnel failed: missing vpn options")
      diag("startup_failure phase=vpn_options_missing")
      completionHandler(PacketTunnelProviderError.missingVPNOptions)
      return
    }
    let vpnOptions = snapshot.options
    logger.info(
      "startTunnel options stack=\(vpnOptions.stack, privacy: .public) ipv6=\(vpnOptions.ipv6, privacy: .public) captureDns=\(vpnOptions.captureDns, privacy: .public) systemProxy=\(vpnOptions.systemProxy, privacy: .public)"
    )
    SwitchDiagnostics.record("ipad_vpn_options", fields: ["success": "true", "attempt_id": ownedAttempt.uuidString])
    let setupParamsData = sharedStateStore.loadSetupParams()
    SwitchDiagnostics.record("ipad_setup_params", fields: ["count": String(setupParamsData.count), "attempt_id": ownedAttempt.uuidString])
    diag(
      "vpn_options stack=\(vpnOptions.stack) ipv6=\(vpnOptions.ipv6) captureDns=\(vpnOptions.captureDns) systemProxy=\(vpnOptions.systemProxy) mtu=\(vpnOptions.mtu) routeCount=\(vpnOptions.routeAddress.count)"
    )
    diag(
      "setup_params bytes=\(setupParamsData.count) empty=\(setupParamsData.count <= 2)"
    )


    diagnosticStage = "network_settings"
    SwitchDiagnostics.record("ipad_network_settings", fields: ["attempt_id": ownedAttempt.uuidString])
    setTunnelNetworkSettings(
      networkConfiguration.makeSettings(for: vpnOptions)
    ) { error in
      DispatchQueue.main.async {
        guard self.activeCleanup === cleanup else { return }
        if let error {
          self.logger.error(
            "setTunnelNetworkSettings failed"
          )
          self.diag("startup_failure phase=set_network_settings")
          completionHandler(error)
          return
        }
        self.logger.info("setTunnelNetworkSettings completed")
        self.diag("set_network_settings ok")
        self.diagnosticStage = "tunnel_fd"
        SwitchDiagnostics.record("ipad_network_settings", fields: ["success": "true", "attempt_id": ownedAttempt.uuidString])
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
        SwitchDiagnostics.record("ipad_tunnel_fd", fields: ["success": String(tunnelFileDescriptor >= 0), "attempt_id": ownedAttempt.uuidString])
        self.diag("tunnel_fd=\(tunnelFileDescriptor)")
        self.eventQueue.start()
        self.eventQueueStarted = true

        self.diag(
          "mem_before_quick_setup footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
        )
        // Diagnostic admission is asynchronous; startup never flushes disk.
        // Start sampling before the config load so a jetsam kill while the core
        // builds rule-provider matchers leaves a footprint trail instead of silence.
        self.resourceHeartbeat.start()
        let initParams = self.sharedStateStore.makeInitParams()
        let setupParams = self.sharedStateStore.loadSetupParams()
        self.logger.info(
          "quickSetup initParams prepared"
        )
        self.diagnosticStage = "quick_setup"
        SwitchDiagnostics.record("ipad_init_core", fields: ["attempt_id": ownedAttempt.uuidString])
        SwitchDiagnostics.record("ipad_quick_setup", fields: ["attempt_id": ownedAttempt.uuidString])
        self.coreSetupOwner = cleanup
        NECoreBridge.quickSetup(
          withInitParams: initParams,
          setupParams: setupParams
        ) { result in
          DispatchQueue.main.async {
            guard self.coreSetupOwner === cleanup else { return }
            guard self.activeCleanup === cleanup else {
              // Preserve setup occupancy until both old GC and late setup's
              // listener shutdown finish. No main synchronous native work.
              self.coreReclaimRetiring = true
              self.resourceHeartbeat.retire { [weak self] in
                NECoreBridge.stopTun()
                DispatchQueue.main.async {
                  guard let self, self.coreSetupOwner === cleanup else { return }
                  self.coreSetupOwner = nil
                  self.coreReclaimRetiring = false
                }
              }
              return
            }
            self.coreSetupOwner = nil
            if let result,
              !result.isEmpty
            {
              self.logger.error(
                "quickSetup failed"
              )
              self.diag("startup_failure phase=quick_setup")
              completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
              return
            }
            self.logger.info("quickSetup completed")
            self.diag(
              "quick_setup ok footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
            )
            // Diagnostic admission is asynchronous; startup never flushes disk.
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
              // Diagnostic admission is asynchronous; startup never flushes disk.
              completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
              return
            }
            self.diag(
              "tun_start begin footprint_mb=\(NativeResourceHeartbeat.footprintSampleMB())"
            )
            // Diagnostic admission is asynchronous; startup never flushes disk.
            self.diagnosticStage = "start_tun"
            SwitchDiagnostics.record("ipad_quick_setup", fields: ["success": "true", "attempt_id": ownedAttempt.uuidString])
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
            // Diagnostic admission is asynchronous; startup never flushes disk.
            SwitchDiagnostics.record("ipad_start_tun", fields: ["success": String(started), "attempt_id": ownedAttempt.uuidString])
            if started {
              self.diagnosticStage = "command_server"
              self.sharedStateStore.saveRunTime(vpnOptions: snapshot.data)
              guard self.commandServer.start(attempt: self.lifecycleGeneration) else {
                completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
                return
              }
              self.commandServerStarted = true
            }
            completionHandler(
              started ? nil : PacketTunnelProviderError.couldNotStartCoreTun
            )
          }
        }
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    // Register before main dispatch and before any I/O or native operation.
    let completion = NativeStopCompletion(completion: completionHandler)
    stopTunnelOnMain(with: reason, completionHandler: { completion.finish() })
  }

  private func stopTunnelOnMain(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.stopTunnelOnMain(with: reason, completionHandler: completionHandler)
      }
      return
    }
    SwitchDiagnostics.record("tunnel_stop", fields: ["reason": String(reason.rawValue)])
    lifecycleGeneration = UUID()
    let startupCompletion = pendingStartupCompletion
    pendingStartupCompletion = nil
    activeCleanup?.cleanup()
    activeCleanup = nil
    SwitchDiagnostics.record("ipad_stop", fields: ["count": String(reason.rawValue)])
    logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
    sharedStateStore.clearRunTime()
    reloadWidgets()
    // Native shutdown belongs to the async heartbeat retirement above.
    diagnosticStage = "cancelled"
    SwitchDiagnostics.record("ipad_cancelled")
    startupCompletion?(diagnosticError(PacketTunnelProviderError.couldNotStartCoreTun))
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
      guard
        let manager = managers?.first(where: { manager in
          guard
            let proto = manager.protocolConfiguration
              as? NETunnelProviderProtocol
          else {
            return false
          }
          return proto.providerBundleIdentifier == PacketTunnelEnvironment.extensionBundleIdentifier
        })
      else {
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
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.handleAppMessage(messageData, completionHandler: completionHandler)
      }
      return
    }
    let generation = lifecycleGeneration
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
        "error_type": SwitchDiagnostics.responseErrorType(response, method: method),
        "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - receivedAt) * 1000)),
      ])
      completionHandler(response)
    }

    NECoreBridge.invokeMethod(messageData) { response in
      DispatchQueue.main.async {
        guard self.lifecycleGeneration == generation else {
          reply(self.methodErrorResponse(messageData: messageData, code: "empty_response", message: "tunnel lifecycle changed"))
          return
        }
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
        // Raw native messages carry no mailbox owner. Their real response is
        // sufficient; never manufacture a disk receipt usable by a different RPC.
        reply(response)
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    SwitchDiagnostics.record("tunnel_sleep")
    completionHandler()
  }

  override func wake() {
    SwitchDiagnostics.record("tunnel_wake")
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
    guard
      let object = try? JSONSerialization.jsonObject(with: messageData)
        as? [String: Any]
    else {
      return nil
    }
    return object["id"] as? String
  }

  private func reloadWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
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
