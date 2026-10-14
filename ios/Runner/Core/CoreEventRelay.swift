import Foundation
import CoreFoundation

/// A single ACK-driven window. Disk enumeration/read/delete run off main;
/// notifications never enqueue a payload and coalesce before dispatch.
final class CoreEventRelay {
  private let sharedStateStore: SharedStateStore
  private let sendEvent: (String, @escaping (Bool) -> Void) -> Void
  private let worker = DispatchQueue(label: "com.follow.clash.runner-events")
  private let producer = DispatchQueue(label: "com.follow.clash.runner-event-producer")
  private var lastLocalTimestamp: UInt64 = 0
  private let notificationLock = NSLock()
  private var notificationPending = false
  private var retryRequested = false
  private var isStarted = false
  private var generation = UUID()
  private var deliveryToken: UUID?
  private var retryBlocked = false
  // Worker-owned retry metadata only: never capture the event String/Data.
  private var retryWork: DispatchWorkItem?
  private var retryToken: UUID?
  private var retryAttempt = 0
  private var stopped = false
  private var acknowledgedFile: (url: URL, identity: String, owner: UUID)?

  init(sharedStateStore: SharedStateStore,
       sendEvent: @escaping (String, @escaping (Bool) -> Void) -> Void) {
    self.sharedStateStore = sharedStateStore
    self.sendEvent = sendEvent
  }

  deinit {
    retryWork?.cancel()
    if isStarted {
      CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(self).toOpaque(),
        CFNotificationName(sharedStateStore.eventNotificationName as CFString), nil)
    }
  }

  // Registration is called once from ServiceChannel/main.
  func start() {
    guard !isStarted else { return }
    isStarted = true
    worker.async { [self] in stopped = false }
    // The ObjC bridge owns one independent producer slot BEFORE NSString
    // allocation; no per-event main async closures, no shared RPC callback wait.
    IOSCoreBridge.setEventListener { [weak self] event in
      guard let self, let event, !event.isEmpty else { return }
      self.producer.sync {
        while true {
          do {
            guard let directory = self.sharedStateStore.eventQueueDirectory() else {
              Thread.sleep(forTimeInterval: 1)
              continue
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = max(UInt64(Date().timeIntervalSince1970 * 1_000_000), self.lastLocalTimestamp + 1)
            self.lastLocalTimestamp = timestamp
            let name = "\(timestamp)-\(UUID().uuidString).json"
            #if IOS_MEMORY_TESTING
            self.beforeLocalWrite?()
            #endif
            try event.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            break
          } catch {
            // One payload stays on the event-only producer. Never falsely ACK
            // or queue more payloads after a transient disk failure.
            NSLog("CoreEventRelay local event persistence failed: %@", error.localizedDescription)
            Thread.sleep(forTimeInterval: 1)
          }
        }
      }
      self.handleEventNotification()
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(), Self.eventNotificationCallback,
      sharedStateStore.eventNotificationName as CFString, nil, .deliverImmediately)
    drainEventQueue()
  }

  func drainEventQueue() {
    scheduleDrain(allowRetry: true)
  }

  /// Reset invalidates ACK authority, not the real Flutter occupancy. A hung
  /// old delivery must not permit another payload. No late ACK can delete a
  /// reused pathname; reset never deletes unacknowledged files.
  func reset() {
    worker.async { [self] in
      cancelRetry()
      generation = UUID(); retryBlocked = false; acknowledgedFile = nil
    }
  }

  /// Registration is main-owned, like start(). Keep actual Flutter occupancy.
  func stop() {
    if isStarted {
      CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(self).toOpaque(),
        CFNotificationName(sharedStateStore.eventNotificationName as CFString), nil)
      isStarted = false
    }
    worker.async { [self] in
      stopped = true
      cancelRetry()
      generation = UUID(); retryBlocked = false; acknowledgedFile = nil
    }
  }

  private func cancelRetry() {
    retryWork?.cancel()
    retryWork = nil; retryToken = nil; retryAttempt = 0
  }

  private func blockForRetry() {
    retryBlocked = true
    guard !stopped, retryWork == nil else { return }
    retryAttempt = min(retryAttempt + 1, 6)
    let delay = min(0.25 * pow(2.0, Double(retryAttempt - 1)), 8.0)
    let token = UUID(), owner = generation
    retryToken = token
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped, self.generation == owner,
        self.retryToken == token else { return }
      self.retryWork = nil; self.retryToken = nil
      self.retryBlocked = false
      self.pump()
    }
    retryWork = item
    #if IOS_MEMORY_TESTING
    if let scheduleTestRetry { scheduleTestRetry(delay, item); return }
    #endif
    worker.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func handleEventNotification() { scheduleDrain(allowRetry: false) }

  private func scheduleDrain(allowRetry: Bool) {
    notificationLock.lock()
    retryRequested = retryRequested || allowRetry
    guard !notificationPending else { notificationLock.unlock(); return }
    notificationPending = true
    notificationLock.unlock()
    worker.async { [weak self] in
      guard let self else { return }
      self.notificationLock.lock()
      self.notificationPending = false
      let retry = self.retryRequested
      self.retryRequested = false
      self.notificationLock.unlock()
      if retry { self.cancelRetry(); self.retryBlocked = false }
      self.pump()
    }
  }

  /// Find the oldest path with one retained URL, not all N URLs sorted in RAM.
  /// The durable backlog is intentionally not truncated to a guessed disk cap.
  private func oldestFile(in directory: URL) -> URL? {
    guard let iterator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return nil }
    var oldest: URL?
    for case let url as URL in iterator {
      guard url.pathExtension == "json",
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      if oldest == nil || url.lastPathComponent < oldest!.lastPathComponent { oldest = url }
    }
    return oldest
  }

  // Published event files are immutable. Identity catches external replacement
  // of the same pathname (reset/token catches late callbacks within this relay).
  private func identity(_ url: URL) -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let inode = attrs[.systemFileNumber], let created = attrs[.creationDate],
      let size = attrs[.size] else { return nil }
    return "\(inode):\(created):\(size)"
  }

  private func pump() {
    guard !stopped, deliveryToken == nil, !retryBlocked else { return }
    if let ack = acknowledgedFile {
      let currentIdentity = identity(ack.url)
      if ack.owner == generation && currentIdentity == nil &&
        FileManager.default.fileExists(atPath: ack.url.path) {
        blockForRetry(); return
      }
      if ack.owner == generation && currentIdentity == ack.identity {
        do {
          #if IOS_MEMORY_TESTING
          try beforeDelete?()
          #endif
          try FileManager.default.removeItem(at: ack.url)
        } catch { blockForRetry(); return }
      }
      acknowledgedFile = nil
      cancelRetry()
    }
    guard let directory = sharedStateStore.eventQueueDirectory(),
      let file = oldestFile(in: directory) else { return }
    guard let fileIdentity = identity(file) else { blockForRetry(); return }
    let event: String
    do {
      #if IOS_MEMORY_TESTING
      try beforeRead?()
      #endif
      event = try String(contentsOf: file, encoding: .utf8)
    } catch { blockForRetry(); return }
    guard !event.isEmpty else {
      // Preserve unreadable/invalid critical files and order. Retry metadata
      // contains no payload; permanent faults back off rather than spin.
      blockForRetry()
      return
    }
    let token = UUID(), owner = generation
    deliveryToken = token
    let ackLock = NSLock()
    var acknowledged = false
    sendEvent(event) { [weak self] delivered in
      // Count duplicate replies before Dispatch admission as well.
      ackLock.lock()
      guard !acknowledged else { ackLock.unlock(); return }
      acknowledged = true
      ackLock.unlock()
      self?.worker.async { [weak self] in
        guard let self, self.deliveryToken == token else { return }
        guard self.generation == owner else {
          self.deliveryToken = nil
          self.pump()
          return
        }
        guard delivered else { self.deliveryToken = nil; self.blockForRetry(); return }
        self.deliveryToken = nil
        self.acknowledgedFile = (file, fileIdentity, owner)
        self.pump()
      }
    }
  }

  private static let eventNotificationCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    Unmanaged<CoreEventRelay>.fromOpaque(observer).takeUnretainedValue().handleEventNotification()
  }

  #if IOS_MEMORY_TESTING
  var beforeDelete: (() throws -> Void)?
  var beforeRead: (() throws -> Void)?
  var scheduleTestRetry: ((Double, DispatchWorkItem) -> Void)?
  func testRetryPending() -> Bool { worker.sync { retryWork != nil } }
  func testRetryAttempt() -> Int { worker.sync { retryAttempt } }
  func testFireRetry() { worker.sync { retryWork?.perform() } }
  func testPerformStale(_ item: DispatchWorkItem) { worker.sync { item.perform() } }
  var beforeLocalWrite: (() -> Void)?
  func flush() { worker.sync {} }
  func testInFlight() -> Int { worker.sync { deliveryToken == nil ? 0 : 1 } }
  #endif
}
