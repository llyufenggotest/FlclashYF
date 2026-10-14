import Foundation
import CoreFoundation
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
  private let admission = NSCondition()
  private var occupied = false
  private var running = false
  private var generation = UUID()
  #if IOS_MEMORY_TESTING
  var beforeWrite: (() -> Void)?
  func flush() { queue.sync {} }
  #endif

  init(sharedStateStore: PacketTunnelSharedStateStore) {
    self.sharedStateStore = sharedStateStore
  }

  func start() {
    admission.lock()
    guard !running else { admission.unlock(); return }
    running = true
    let generation = UUID()
    self.generation = generation
    admission.unlock()
    NECoreBridge.setEventListener { [weak self] event in
      guard let self, let event, !event.isEmpty else { return }
      self.admit(event, generation: generation)
    }
  }

  private func admit(_ event: Data, generation: UUID) {
    // The ObjC event-only producer lane waits here, never RPC/main. One
    // payload owns the worker, including its executing disk write. No cap or
    // truncation of critical payloads; pressure propagates to this producer.
    admission.lock()
    while occupied && running && self.generation == generation { admission.wait() }
    guard running, self.generation == generation else { admission.unlock(); return }
    occupied = true
    admission.unlock()
    queue.async { [self] in
      // A transient storage error never silently retires a critical payload.
      // Keep exactly this one producer-owned payload and retry off main/RPC.
      while !enqueue(event) { Thread.sleep(forTimeInterval: 1) }
      admission.lock()
      occupied = false
      admission.broadcast()
      admission.unlock()
    }
    admission.lock()
    while occupied { admission.wait() }
    admission.unlock()
  }

  func stop() {
    admission.lock()
    running = false
    generation = UUID()
    admission.broadcast()
    admission.unlock()
    // Already-admitted event finishes durably; old callbacks cannot admit a
    // new payload. Listener replacement does not wait for its producer lane.
    NECoreBridge.setEventListener(nil)
  }

  func markCoreResponsive() {
    // Compatibility no-op. No main->event I/O barrier.
  }

  private var lastTimestamp: UInt64 = 0
  private func enqueue(_ event: Data) -> Bool {
    #if IOS_MEMORY_TESTING
    beforeWrite?()
    #endif
    guard let directory = eventQueueDirectory() else {
      logger.error("enqueue failed: missing app group dir")
      return false
    }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let timestamp = max(UInt64(Date().timeIntervalSince1970 * 1_000_000), lastTimestamp + 1)
      lastTimestamp = timestamp
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
      if suffix == ".lossy.json" { prune(in: directory) }
      notifyEventAvailable()
      return true
    } catch {
      logger.error(
        "enqueue failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
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
