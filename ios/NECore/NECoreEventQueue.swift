import Foundation
import os

final class NECoreEventQueue {
  private let sharedStateStore: PacketTunnelSharedStateStore
  private let eventQueueDirectoryName = "core-events"
  private let maxEventQueueFiles = 10
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "NECoreEventQueue"
  )

  private let queue = DispatchQueue(label: "com.follow.clash.event-queue")
  private var running = false
  private var generation = UUID()

  init(sharedStateStore: PacketTunnelSharedStateStore) {
    self.sharedStateStore = sharedStateStore
  }

  func start() {
    queue.sync { [weak self] in
      guard let self, !self.running else { return }
      self.running = true
      let generation = UUID()
      self.generation = generation
      NECoreBridge.setEventListener { [weak self] event in
        guard let self, let event, !event.isEmpty else { return }
        // NECoreResult calls this listener synchronously on its single serial
        // callback queue. Backpressure leaves at most one native event in this
        // path, instead of retaining arbitrarily many Dispatch payload closures.
        self.queue.sync {
          guard self.running, self.generation == generation else { return }
          self.enqueue(event)
        }
      }
    }
  }

  func stop() {
    queue.sync { [weak self] in
      guard let self else { return }
      self.running = false
      self.generation = UUID()
      NECoreBridge.setEventListener(nil)
    }
  }

  func markCoreResponsive() {
    queue.sync { [weak self] in
      guard let self else { return }
      guard self.running else { return }
      // Retained for the provider API; backlog must not disable critical events.
    }
  }

  private func enqueue(_ event: Data) {
    guard let directory = eventQueueDirectory() else {
      logger.error("enqueue failed: missing app group dir")
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
      let fileName = "\(timestamp)-\(UUID().uuidString)"
      let suffix = Self.isDiscardable(event) ? ".lossy.json" : ".json"
      let fileURL = directory.appendingPathComponent("\(fileName)\(suffix)")
      let temporaryURL = directory.appendingPathComponent(".\(fileName).tmp")
      do {
        try event.write(to: temporaryURL)
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
      prune(in: directory)
      notifyEventAvailable()
    } catch {
      logger.error(
        "enqueue failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Mirror only the core's existing bulk eviction contract. Mixed batches,
  /// loaded/geoUpdate state, delay acknowledgements and unknown future events
  /// are critical: never delete an entire batch containing any of those.
  static func isDiscardable(_ event: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: event) as? [String: Any],
      object["method"] as? String == "message",
      let messages = object["arguments"] as? [[String: Any]], !messages.isEmpty
    else { return false }
    return messages.allSatisfy {
      guard let type = $0["type"] as? String else { return false }
      return ["log", "request", "dns"].contains(type)
    }
  }

  private func prune(in directory: URL) {
    // Stream the directory; keep at most eleven URL objects even when the
    // intentionally lossless critical backlog is large. Only lossy files prune.
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
    ) else { return }
    var newest: [URL] = []
    for case let url as URL in enumerator {
      guard url.lastPathComponent.hasSuffix(".lossy.json"),
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { continue }
      newest.append(url)
      newest.sort { $0.lastPathComponent < $1.lastPathComponent }
      if newest.count > maxEventQueueFiles { removeOldestEventFile(&newest) }
    }
  }

  private func removeOldestEventFile(_ files: inout [URL]) {
    let fileURL = files.removeFirst()
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      logger.warning(
        "prune failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func eventQueueDirectory() -> URL? {
    sharedStateStore.appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  private func notifyEventAvailable() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(
        PacketTunnelEnvironment.eventNotificationName as CFString
      ),
      nil,
      nil,
      true
    )
  }
}
