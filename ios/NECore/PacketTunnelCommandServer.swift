import Foundation
import os

/// File + Darwin RPC server for the Network Extension side.
///
/// `sendProviderMessage` can be dropped before it reaches `handleAppMessage`
/// under some sideload/resign configs, so control-plane requests silently fail
/// while the tunnel keeps running. This mirrors each request through the shared
/// App Group container, which the extension already uses for config and events.
final class PacketTunnelCommandServer {
  private let sharedStateStore: PacketTunnelSharedStateStore
  private let invoke: (Data, @escaping (Data?) -> Void) -> Void
  private let queue = DispatchQueue(
    label: "com.follow.clash.command-server"
  )
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "PacketTunnelCommandServer"
  )
  private let directoryName = "core-rpc"
  private let requestExtension = "req"
  private let responseExtension = "resp"
  private let maxOrphanAge: TimeInterval = 180
  private let pollInterval: DispatchTimeInterval = .milliseconds(200)

  private var running = false
  private var timer: DispatchSourceTimer?
  // Each admission owns a token, not just a reusable mailbox filename.
  // Do not impose a server deadline: configuration clients allow 120 seconds.
  private var inFlight: [String: UUID] = [:]

  init(
    sharedStateStore: PacketTunnelSharedStateStore,
    invoke: @escaping (Data, @escaping (Data?) -> Void) -> Void
  ) {
    self.sharedStateStore = sharedStateStore
    self.invoke = invoke
  }

  func start() {
    queue.async { [weak self] in
      guard let self, !self.running else { return }
      self.running = true
      self.registerObserver()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(
        deadline: .now() + self.pollInterval,
        repeating: self.pollInterval
      )
      timer.setEventHandler { [weak self] in
        self?.drain()
      }
      self.timer = timer
      timer.resume()
      self.drain()
    }
  }

  func stop() {
    queue.sync { [weak self] in
      guard let self, self.running else { return }
      self.running = false
      self.timer?.cancel()
      self.timer = nil
      self.inFlight.removeAll()
      self.removeObserver()
    }
  }

  private func registerObserver() {
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      PacketTunnelCommandServer.notificationCallback,
      PacketTunnelEnvironment.commandNotificationName as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func removeObserver() {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(
        PacketTunnelEnvironment.commandNotificationName as CFString
      ),
      nil
    )
  }

  private func drain() {
    guard running, let requestDirectory = requestDirectory() else { return }
    pruneOrphans()
    // Client owns deadlines; configuration can legitimately take >30 seconds.
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: requestDirectory,
      includingPropertiesForKeys: nil
    ) else {
      return
    }
    for fileURL in files
      .filter({ $0.pathExtension == requestExtension })
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let id = fileURL.deletingPathExtension().lastPathComponent
      guard inFlight[id] == nil else { continue }
      guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
        try? FileManager.default.removeItem(at: fileURL)
        inFlight.removeValue(forKey: id)
        continue
      }
      // Consume the request immediately so a mid-flight restart cannot run it
      // twice; the response is keyed by the same id.
      try? FileManager.default.removeItem(at: fileURL)
      let token = UUID()
      inFlight[id] = token
      process(id: id, token: token, data: data)
    }
  }

  private func process(id: String, token: UUID, data: Data) {
    let receivedAt = ProcessInfo.processInfo.systemUptime
    let requestID = SwitchDiagnostics.requestID(data)
    let method = SwitchDiagnostics.method(data)
    SwitchDiagnostics.record("rpc_received", fields: [
      "request_id": requestID,
      "method": method,
      "request_bytes": String(data.count),
    ])
    let configurationWrite = method == "setupConfig" || method == "updateConfig"
    if configurationWrite {
      sharedStateStore.clearConfigurationRequestApplied()
    }
    invoke(data) { [weak self] response in
      guard let self else { return }
      self.queue.async {
        guard self.running, self.inFlight[id] == token else {
          self.logger.debug("ignoring late RPC response id=\(id, privacy: .public)")
          return
        }
        let payload = response ?? self.emptyCoreResponse(for: data)
        if configurationWrite,
          let response,
          let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
          object["error"] == nil || object["error"] is NSNull,
          let result = object["result"] as? String,
          result.isEmpty {
          self.sharedStateStore.markConfigurationRequestApplied(requestID)
        }
        self.writeResponse(id: id, data: payload)
        SwitchDiagnostics.record("rpc_reply", fields: [
          "request_id": requestID,
          "method": method,
          "response_bytes": String(response?.count ?? 0),
          "status": response == nil ? "nil_response" : "response",
          "elapsed_ms": String(
            Int((ProcessInfo.processInfo.systemUptime - receivedAt) * 1000)
          ),
        ])
        self.inFlight.removeValue(forKey: id)
      }
    }
  }

  // Pending admissions are invalidated on stop, without changing RPC errors.
  private func writeResponse(id: String, data: Data) {
    guard let responseDirectory = responseDirectory() else { return }
    do {
      try FileManager.default.createDirectory(
        at: responseDirectory,
        withIntermediateDirectories: true
      )
      let destination = responseDirectory
        .appendingPathComponent("\(id).\(responseExtension)")
      let temporary = responseDirectory
        .appendingPathComponent(".\(id).tmp")
      try data.write(to: temporary)
      if FileManager.default.fileExists(atPath: destination.path) {
        try? FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      logger.error(
        "writeResponse failed: \(error.localizedDescription, privacy: .public)"
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

  private func emptyCoreResponse(for data: Data) -> Data {
    var payload: [String: Any] = [
      "result": NSNull(),
      "error": [
        "code": "empty_response",
        "message": "empty core response",
        "details": NSNull(),
      ],
    ]
    if let object = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      let id = object["id"] as? String {
      payload["id"] = id
    }
    return (try? JSONSerialization.data(withJSONObject: payload))
      ?? Data(#"{"result":null,"error":{"code":"empty_response","message":"empty core response","details":null}}"#.utf8)
  }

  private func rpcDirectory() -> URL? {
    sharedStateStore.appGroupDirectory()?
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  private func requestDirectory() -> URL? {
    rpcDirectory()?.appendingPathComponent("req", isDirectory: true)
  }

  private func responseDirectory() -> URL? {
    rpcDirectory()?.appendingPathComponent("resp", isDirectory: true)
  }

  private static let notificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    let server = Unmanaged<PacketTunnelCommandServer>
      .fromOpaque(observer)
      .takeUnretainedValue()
    server.queue.async {
      server.drain()
    }
  }
}
