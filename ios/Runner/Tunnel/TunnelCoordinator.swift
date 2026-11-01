import Foundation
import NetworkExtension
import os

@MainActor
final class TunnelCoordinator {
  private let managerStore: TunnelManagerStore
  private let onTunnelStateChanged: (TunnelTarget) -> Void
  private let onConnectionStateChanged: (String) -> Void
  private let onExternalStart: () -> Void
  private let onExternalStop: () -> Void
  private let setAppDNSSuspended: (Bool) async -> Bool
  // Ordered ABI lane: late resume must finish before a newer suspend/start.
  private var appDNSOperation: Task<Bool, Never>?
  private var appDNSOperationGeneration: UInt64 = 0
  private var appDNSWasSuspended = false
  private var dnsOwnershipRevision: UInt64 = 0
  private let connectTimeout: TimeInterval = 5
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.chenx.flclash",
    category: "TunnelCoordinator"
  )

  private var observedTunnelStatus: NEVPNStatus?
  private var reportedTunnelState: TunnelTarget?
  private var publishedTunnelState: TunnelTarget?

  private var requestGeneration: UInt64 = 0
  private var tunnelRequest: TunnelRequest?
  private var tunnelWait: TunnelWait?
  private var isCoordinatorRunning = false
  // A start that supersedes a stop before it stopped anything must still
  // cycle the tunnel, or a restart meant to apply new options is lost.
  private var restartOwed = false
  // Diagnostic ownership is separate from lifecycle/transport ownership.
  private var diagnosticConnectingGeneration: UInt64?
  private var diagnosticFetchedGeneration: UInt64?
  // A failed restart must not publish the unchanged old connection as success.
  // Keep the observed NE status intact; retire this failure on a new request
  // or a real status transition, not on a refresh of the same connected tunnel.
  private var failedRestartGeneration: UInt64?

  private var configurationContinuations: [CheckedContinuation<Void, Error>] = []
  private var needsStatusRefresh = false
  private var statusRefreshShouldNotify = false

  init(
    managerStore: TunnelManagerStore,
    onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
    onConnectionStateChanged: @escaping (String) -> Void,
    onExternalStart: @escaping () -> Void,
    onExternalStop: @escaping () -> Void,
    setAppDNSSuspended: @escaping (Bool) async -> Bool = { await CoreMessageRouter.setAppDNSListenerSuspended($0) }
  ) {
    self.managerStore = managerStore
    self.onTunnelStateChanged = onTunnelStateChanged
    self.onConnectionStateChanged = onConnectionStateChanged
    self.onExternalStart = onExternalStart
    self.onExternalStop = onExternalStop
    self.setAppDNSSuspended = setAppDNSSuspended
  }

  deinit {
    tunnelWait?.timeoutWork?.cancel()
  }

  func submitTunnelRequest(
    target: TunnelTarget,
    notifyExternalOnCompletion: Bool = false
  ) {
    if let request = tunnelRequest,
      request.target == target
    {
      request.notifyExternalOnCompletion =
        request.notifyExternalOnCompletion || notifyExternalOnCompletion
      log("merge \(target.description) request")
      return
    }

    if target == .stopped {
      restartOwed = true
    }
    requestGeneration &+= 1
    failedRestartGeneration = nil
    let request = TunnelRequest(
      generation: requestGeneration,
      target: target,
      notifyExternalOnCompletion: notifyExternalOnCompletion
    )
    tunnelRequest = request
    publishConnectionState()
    publishedTunnelState = target
    cancelTunnelWait()
    log(
      "request target=\(target.description) generation=\(request.generation)"
    )

    driveCoordinator()
  }

  // Configuration admission and lifecycle share exactly the same App DNS lane.
  // A failed/unknown manager lookup must never restore App ownership.
  func prepareAppDNSForConfiguration() async -> Bool {
    let generation = requestGeneration
    let revision = dnsOwnershipRevision
    do {
      let manager = try await managerStore.loadManager(createIfNeeded: false)
      guard generation == requestGeneration, revision == dnsOwnershipRevision else { return false }
      let status = manager?.connection.status ?? .invalid
      if status.isLifecycleActive || tunnelRequest?.target == .running {
        let success = await changeAppDNSOwnership(suspended: true)
        return success && generation == requestGeneration && revision == dnsOwnershipRevision
      }
      if appDNSWasSuspended {
        recordObservedTunnelStatus(status, notifyExternal: false)
        return await restoreAppDNSIfStopped()
      }
      return true
    } catch { return false }
  }

  private func changeAppDNSOwnership(suspended: Bool) async -> Bool {
    // Register debt before suspension so a concurrent terminal stop queues its
    // restore behind this operation, even when the bridge reply arrives late.
    if suspended { appDNSWasSuspended = true }
    appDNSOperationGeneration &+= 1
    let operationGeneration = appDNSOperationGeneration
    let previous = appDNSOperation
    let action = setAppDNSSuspended
    let operation = Task { @MainActor in
      if let previous { _ = await previous.value }
      return await action(suspended)
    }
    appDNSOperation = operation
    let success = await operation.value
    if operationGeneration == appDNSOperationGeneration { appDNSOperation = nil }
    return success
  }

  private func restoreAppDNSIfStopped() async -> Bool {
    guard appDNSWasSuspended,
      tunnelRequest?.target != .running,
      observedTunnelStatus?.isTerminal == true
    else { return !appDNSWasSuspended }
    let generation = requestGeneration
    let revision = dnsOwnershipRevision
    appDNSOperationGeneration &+= 1
    let operationGeneration = appDNSOperationGeneration
    let previous = appDNSOperation
    let operation = Task { @MainActor [weak self] in
      if let previous { _ = await previous.value }
      guard let self, generation == self.requestGeneration,
        revision == self.dnsOwnershipRevision,
        self.tunnelRequest?.target != .running,
        self.observedTunnelStatus?.isTerminal == true
      else { return false }
      // Re-read the actual managed connection; a queued old stopped report is
      // not authority to bind while an external/on-demand start is connecting.
      do {
        let manager = try await self.managerStore.loadManager(createIfNeeded: false)
        guard generation == self.requestGeneration, revision == self.dnsOwnershipRevision,
          self.tunnelRequest?.target != .running,
          manager?.connection.status.isLifecycleActive != true
        else { return false }
      } catch { return false }
      return await self.setAppDNSSuspended(false)
    }
    appDNSOperation = operation
    let success = await operation.value
    if operationGeneration == appDNSOperationGeneration { appDNSOperation = nil }
    guard generation == requestGeneration, revision == dnsOwnershipRevision,
      operationGeneration == appDNSOperationGeneration else { return false }
    if success { appDNSWasSuspended = false }
    return success
  }

  func toggleTunnelRequest() {
    let currentTarget = tunnelRequest?.target ??
      observedTunnelStatus?.tunnelState ??
      publishedTunnelState ??
      .stopped
    submitTunnelRequest(
      target: currentTarget == .running ? .stopped : .running
    )
  }

  func reloadOnDemandRules() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      configurationContinuations.append(continuation)
      driveCoordinator()
    }
  }

  func requestStatusRefresh(notifyExternal: Bool) {
    needsStatusRefresh = true
    statusRefreshShouldNotify =
      statusRefreshShouldNotify || notifyExternal
    driveCoordinator()
  }

  func publishConnectionState() {
    let state: String
    if tunnelRequest != nil {
      state = "pending"
    } else if failedRestartGeneration == requestGeneration {
      state = "disconnected"
    } else {
      switch observedTunnelStatus {
      case .connected:
        state = "connected"
      case .disconnected, .invalid:
        state = "disconnected"
      default:
        state = "pending"
      }
    }
    onConnectionStateChanged(state)
  }

  func ownsStatusConnection(_ connection: NEVPNConnection) -> Bool {
    guard managerStore.isManagedConnection(connection) else { return false }
    if let wait = tunnelWait { return wait.manager.connection === connection }
    return managerStore.isCachedConnection(connection)
  }

  func handleTunnelStatusNotification(_ notification: Notification) {
    guard let connection = notification.object as? NEVPNConnection,
      ownsStatusConnection(connection) else { return }

    if let wait = tunnelWait,
      wait.manager.connection === connection
    {
      recordObservedTunnelStatus(
        connection.status,
        notifyExternal: false
      )
      return
    }
    guard tunnelWait == nil,
      managerStore.isCachedConnection(connection)
    else {
      return
    }
    recordObservedTunnelStatus(
      connection.status,
      notifyExternal: true
    )
  }

  private func driveCoordinator() {
    guard !isCoordinatorRunning else {
      return
    }
    isCoordinatorRunning = true
    Task { [weak self] in
      await self?.runCoordinator()
    }
  }

  private func runCoordinator() async {
    while true {
      if let request = tunnelRequest {
        await reconcileTunnel(request)
        continue
      }

      if !configurationContinuations.isEmpty {
        let continuations = configurationContinuations
        configurationContinuations.removeAll()
        let error = await performOnDemandRulesReload()
        for continuation in continuations {
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
        continue
      }

      if needsStatusRefresh {
        let notifyExternal = statusRefreshShouldNotify
        needsStatusRefresh = false
        statusRefreshShouldNotify = false
        await performStatusRefresh(notifyExternal: notifyExternal)
        continue
      }

      let ownershipRevision = dnsOwnershipRevision
      if observedTunnelStatus?.isLifecycleActive == true {
        _ = await changeAppDNSOwnership(suspended: true)
      } else if observedTunnelStatus?.isTerminal == true && appDNSWasSuspended {
        _ = await restoreAppDNSIfStopped()
      }
      // A request/status/configuration may arrive while the idle operation awaits.
      if tunnelRequest != nil || !configurationContinuations.isEmpty || needsStatusRefresh || ownershipRevision != dnsOwnershipRevision { continue }
      isCoordinatorRunning = false
      return
    }
  }

  private func reconcileTunnel(_ request: TunnelRequest) async {
    while isCurrent(request) {
      do {
        switch request.target {
        case .running:
          try await reconcileRunningTunnel(request)
        case .stopped:
          try await reconcileStoppedTunnel(request)
        }
        return
      } catch {
        guard isCurrent(request) else {
          return
        }
        let status = observedTunnelStatus
        if request.preferenceRetryCount == 0,
          managerStore.invalidateCachedManager(forPreferenceError: error)
        {
          request.preferenceRetryCount += 1
          log(
            "\(request.target.description) retry preferences: \(error.localizedDescription)"
          )
          continue
        }
        log(
          "\(request.target.description) failed: \(error.localizedDescription)"
        )
        finishTunnelRequest(
          request,
          actualState: stableFailureState(status)
        )
        return
      }
    }
  }

  private func reconcileRunningTunnel(
    _ request: TunnelRequest
  ) async throws {
    while isCurrent(request) {
      let loadedManager = try await managerStore.loadManager()
      guard isCurrent(request) else {
        return
      }
      guard let manager = loadedManager else {
        recordObservedTunnelStatus(.invalid, notifyExternal: false)
        finishTunnelRequest(request, actualState: .stopped)
        return
      }

      let status = manager.connection.status
      recordObservedTunnelStatus(status, notifyExternal: false)
      if status.tunnelState == .running {
        if restartOwed {
          guard await stopBeforeRestart(manager: manager, request: request)
          else {
            return
          }
          continue
        }
        finishTunnelRequest(request, actualState: .running)
        return
      }
      if status.tunnelState == nil {
        guard await settleBeforeStart(manager: manager, request: request) else {
          return
        }
        continue
      }

      manager.isEnabled = true
      managerStore.applyNetworkExtensionOptions(to: manager, enableOnDemand: true)
      log("start save preferences")
      do {
        try await awaitPreferenceResult { completion in
          manager.saveToPreferences(completionHandler: completion)
        }
      } catch {
        guard isCurrent(request) else {
          return
        }
        if finishRunningRequestIfSatisfied(request, manager: manager) {
          return
        }
        throw error
      }
      guard isCurrent(request) else {
        return
      }

      log("start reload preferences")
      do {
        try await awaitPreferenceResult { completion in
          manager.loadFromPreferences(completionHandler: completion)
        }
      } catch {
        guard isCurrent(request) else {
          return
        }
        if finishRunningRequestIfSatisfied(request, manager: manager) {
          return
        }
        throw error
      }
      guard isCurrent(request) else {
        return
      }

      let preparedStatus = manager.connection.status
      recordObservedTunnelStatus(preparedStatus, notifyExternal: false)
      if preparedStatus.tunnelState == .running {
        finishTunnelRequest(request, actualState: .running)
        return
      }
      if preparedStatus.tunnelState == nil {
        guard await settleBeforeStart(manager: manager, request: request) else {
          return
        }
        continue
      }

      let dnsReleased = await changeAppDNSOwnership(suspended: true)
      guard isCurrent(request) else { return }
      guard dnsReleased else {
        throw ProviderMessageError(code: "app_dns_suspend_failed", message: "App DNS listener did not quiesce")
      }
      // Preferences/connection ownership can change across the App Core await.
      guard managerStore.isCachedConnection(manager.connection) else { continue }
      let releasedStatus = manager.connection.status
      if releasedStatus.isLifecycleActive {
        recordObservedTunnelStatus(releasedStatus, notifyExternal: false)
        continue
      }
      do {
        try manager.connection.startVPNTunnel()
        log("start requested")
      } catch {
        if finishRunningRequestIfSatisfied(request, manager: manager) {
          return
        }
        throw error
      }

      let result = await waitForTunnelStatus(
        manager: manager,
        request: request,
        purpose: .starting
      )
      guard isCurrent(request) else {
        return
      }
      switch result {
      case .status(let status):
        finishTunnelRequest(
          request,
          actualState: status.tunnelState
        )
      case .timeout(let status):
        cleanUpFailedStart(manager: manager, status: status)
        finishTunnelRequest(request, actualState: .stopped)
      case .superseded:
        return
      }
      return
    }
  }

  private func settleBeforeStart(
    manager: NETunnelProviderManager,
    request: TunnelRequest
  ) async -> Bool {
    let result = await waitForTunnelStatus(
      manager: manager,
      request: request,
      purpose: .settleThenStart
    )
    guard isCurrent(request) else {
      return false
    }
    switch result {
    case .status(let status):
      if status.tunnelState == .running && !restartOwed {
        finishTunnelRequest(request, actualState: .running)
        return false
      }
      return true
    case .timeout(let status):
      cleanUpFailedStart(manager: manager, status: status)
      finishTunnelRequest(request, actualState: .stopped)
      return false
    case .superseded:
      return false
    }
  }

  private func stopBeforeRestart(
    manager: NETunnelProviderManager,
    request: TunnelRequest
  ) async -> Bool {
    restartOwed = false
    manager.connection.stopVPNTunnel()
    log("restart stop requested")
    let result = await waitForTunnelStatus(
      manager: manager,
      request: request,
      purpose: .stopping
    )
    guard isCurrent(request) else {
      return false
    }
    switch result {
    case .status:
      return true
    case .timeout:
      // Retire this request instead of letting runCoordinator reuse the old
      // connected tunnel as a successful restart. Never retry the stop here.
      failedRestartGeneration = request.generation
      finishTunnelRequest(request, actualState: .stopped)
      return false
    case .superseded:
      return false
    }
  }

  private func reconcileStoppedTunnel(
    _ request: TunnelRequest
  ) async throws {
    guard
      let manager = try await managerStore.loadManager(
        createIfNeeded: false
      )
    else {
      recordObservedTunnelStatus(.invalid, notifyExternal: false)
      finishTunnelRequest(request, actualState: .stopped)
      return
    }
    guard isCurrent(request) else {
      return
    }

    let status = manager.connection.status
    recordObservedTunnelStatus(status, notifyExternal: false)
    if status.tunnelState == .stopped {
      finishTunnelRequest(request, actualState: .stopped)
      return
    }

    if status != .disconnecting {
      manager.connection.stopVPNTunnel()
      log("stop requested from Network Extension")
    }
    let result = await waitForTunnelStatus(
      manager: manager,
      request: request,
      purpose: .stopping
    )
    guard isCurrent(request) else {
      return
    }
    switch result {
    case .status(let status):
      finishTunnelRequest(
        request,
        actualState: status.tunnelState
      )
    case .timeout(let status):
      finishTunnelRequest(
        request,
        actualState: stableFailureState(status)
      )
    case .superseded:
      return
    }
  }

  private func waitForTunnelStatus(
    manager: NETunnelProviderManager,
    request: TunnelRequest,
    purpose: TunnelWaitPurpose
  ) async -> TunnelWaitResult {
    await withCheckedContinuation { continuation in
      let wait = TunnelWait(
        request: request,
        purpose: purpose,
        manager: manager,
        continuation: continuation
      )
      let timeoutWork = DispatchWorkItem { [weak self, weak wait] in
        guard let self,
          let wait,
          self.tunnelWait === wait
        else {
          return
        }
        let status = wait.manager.connection.status
        self.recordObservedTunnelStatus(status, notifyExternal: false)
        guard self.tunnelWait === wait else {
          return
        }
        self.log(
          "wait timeout purpose=\(wait.purpose.description) status=\(self.statusDescription(status))"
        )
        self.resolveTunnelWait(wait, result: .timeout(status))
      }
      wait.timeoutWork = timeoutWork
      tunnelWait = wait
      DispatchQueue.main.asyncAfter(
        deadline: .now() + connectTimeout,
        execute: timeoutWork
      )
      consumeWaitStatus(manager.connection.status)
    }
  }

  private func consumeWaitStatus(_ status: NEVPNStatus) {
    guard let wait = tunnelWait,
      isCurrent(wait.request)
    else {
      return
    }
    switch wait.purpose {
    case .starting:
      if status == .connecting {
        diagnosticConnectingGeneration = wait.request.generation
      }
      if status.tunnelState == .running {
        resolveTunnelWait(wait, result: .status(status))
        return
      }
      if status.isLifecycleActive {
        wait.hasObservedProgress = true
      }
      if status.isTerminal && wait.hasObservedProgress {
        captureLastStartDisconnect(wait)
        resolveTunnelWait(wait, result: .status(status))
      }
    case .stopping:
      if status.isTerminal {
        resolveTunnelWait(wait, result: .status(status))
      }
    case .settleThenStart:
      if status.tunnelState != nil {
        resolveTunnelWait(wait, result: .status(status))
      }
    }
  }

  // Best effort only: no continuation, deadline, retry or lifecycle mutation.
  // The token is captured before the wait resolves; a newer request drops it.
  private func captureLastStartDisconnect(_ wait: TunnelWait) {
    let generation = wait.request.generation
    guard wait.purpose == .starting, isCurrent(wait.request),
      diagnosticConnectingGeneration == generation,
      diagnosticFetchedGeneration != generation
    else { return }
    diagnosticFetchedGeneration = generation
    guard #available(iOS 16.0, macOS 13.0, *) else { return }
    wait.manager.connection.fetchLastDisconnectError { [weak self] error in
      let safeFields = SwitchDiagnostics.disconnectErrorFields(error)
      Task { @MainActor [weak self] in
        guard let self, self.requestGeneration == generation else { return }
        var fields = safeFields
        fields.merge(["stage": "start_tunnel", "generation": String(generation)]) { _, new in new }
        SwitchDiagnostics.record("tunnel_start_disconnect_error", fields: fields)
      }
    }
  }

  private func resolveTunnelWait(
    _ wait: TunnelWait,
    result: TunnelWaitResult
  ) {
    guard tunnelWait === wait else {
      return
    }
    tunnelWait = nil
    wait.timeoutWork?.cancel()
    wait.continuation.resume(returning: result)
  }

  private func cancelTunnelWait() {
    guard let wait = tunnelWait else {
      return
    }
    resolveTunnelWait(wait, result: .superseded)
  }

  private func cleanUpFailedStart(
    manager: NETunnelProviderManager,
    status: NEVPNStatus
  ) {
    if status.isLifecycleActive && status != .disconnecting {
      manager.connection.stopVPNTunnel()
      log("failed start requested cleanup stop")
    }
  }

  private func finishRunningRequestIfSatisfied(
    _ request: TunnelRequest,
    manager: NETunnelProviderManager
  ) -> Bool {
    let status = manager.connection.status
    recordObservedTunnelStatus(status, notifyExternal: false)
    guard status.tunnelState == .running else {
      return false
    }
    finishTunnelRequest(request, actualState: .running)
    return true
  }

  private func finishTunnelRequest(
    _ request: TunnelRequest,
    actualState: TunnelTarget?
  ) {
    guard isCurrent(request) else {
      return
    }
    tunnelRequest = nil
    restartOwed = false
    defer { publishConnectionState() }
    guard let actualState else {
      log(
        "\(request.target.description) completed actual=unknown generation=\(request.generation)"
      )
      return
    }
    reportTunnelState(actualState)
    publishedTunnelState = actualState
    log(
      "\(request.target.description) completed actual=\(actualState.description) generation=\(request.generation)"
    )

    Task { @MainActor [weak self] in
      guard let self,
        self.requestGeneration == request.generation,
        self.tunnelRequest == nil,
        self.publishedTunnelState == actualState
      else {
        return
      }
      self.notifyExternalState(actualState)
    }
  }

  private func isCurrent(_ request: TunnelRequest) -> Bool {
    tunnelRequest === request && requestGeneration == request.generation
  }

  private func performOnDemandRulesReload() async -> Error? {
    var allowPreferenceRetry = true
    while true {
      do {
        guard
          let manager = try await managerStore.loadManager(
            createIfNeeded: false
          )
        else {
          return nil
        }
        let status = manager.connection.status
        managerStore.applyNetworkExtensionOptions(
          to: manager,
          enableOnDemand: status == .connecting || status.tunnelState == .running
        )
        try await awaitPreferenceResult { completion in
          manager.saveToPreferences(completionHandler: completion)
        }
        return nil
      } catch {
        log(
          "reloadOnDemandRules save failed: \(error.localizedDescription)"
        )
        guard allowPreferenceRetry,
          managerStore.invalidateCachedManager(forPreferenceError: error)
        else {
          return error
        }
        allowPreferenceRetry = false
        log("reloadOnDemandRules retry preferences")
      }
    }
  }

  private func performStatusRefresh(notifyExternal: Bool) async {
    let generation = requestGeneration
    do {
      let manager = try await managerStore.loadManager(createIfNeeded: false)
      guard generation == requestGeneration else { return }
      let status = manager?.connection.status ?? .invalid
      recordObservedTunnelStatus(
        status,
        notifyExternal: false
      )
      if notifyExternal,
        generation == requestGeneration,
        failedRestartGeneration != requestGeneration,
        tunnelRequest == nil,
        let state = status.tunnelState
      {
        publishedTunnelState = state
        notifyExternalState(state)
      }
    } catch {
      log("refresh status failed: \(error.localizedDescription)")
    }
  }

  private func recordObservedTunnelStatus(
    _ status: NEVPNStatus,
    notifyExternal: Bool
  ) {
    let previousStatus = observedTunnelStatus
    observedTunnelStatus = status
    defer { publishConnectionState() }
    if previousStatus != status {
      dnsOwnershipRevision &+= 1
      // Wake the serialized owner reconciliation even for connecting and
      // disconnecting, which intentionally do not publish a stopped route.
      driveCoordinator()
      failedRestartGeneration = nil
      log(
        "status changed \(statusDescription(previousStatus ?? .invalid)) -> \(statusDescription(status)) target=\(tunnelRequest?.target.description ?? "none")"
      )
    }

    if tunnelWait != nil {
      consumeWaitStatus(status)
      return
    }
    guard tunnelRequest == nil,
      failedRestartGeneration != requestGeneration,
      let stableState = status.tunnelState
    else {
      return
    }
    reportTunnelState(stableState)
    if notifyExternal {
      publishExternalState(stableState)
    } else if publishedTunnelState == nil {
      publishedTunnelState = stableState
    }
  }

  private func reportTunnelState(_ state: TunnelTarget) {
    guard reportedTunnelState != state else {
      return
    }
    reportedTunnelState = state
    onTunnelStateChanged(state)
  }

  private func publishExternalState(_ state: TunnelTarget) {
    guard publishedTunnelState != state else {
      return
    }
    publishedTunnelState = state
    notifyExternalState(state)
  }

  private func notifyExternalState(_ state: TunnelTarget) {
    switch state {
    case .running:
      log("tunnel started externally")
      onExternalStart()
    case .stopped:
      log("tunnel stopped externally")
      onExternalStop()
    }
  }

  private func awaitPreferenceResult(
    _ action: (@escaping @Sendable (Error?) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      action { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func stableFailureState(
    _ status: NEVPNStatus?
  ) -> TunnelTarget? {
    status?.tunnelState
  }

  private func statusDescription(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
      return "invalid"
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .reasserting:
      return "reasserting"
    case .disconnecting:
      return "disconnecting"
    @unknown default:
      return "unknown"
    }
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
