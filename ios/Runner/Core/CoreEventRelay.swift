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
  private var acknowledgedFile: (url: URL, identity: String, owner: UUID)?

  init(sharedStateStore: SharedStateStore,
       sendEvent: @escaping (String, @escaping (Bool) -> Void) -> Void) {
    self.sharedStateStore = sharedStateStore
    self.sendEvent = sendEvent
  }

  deinit {
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
      generation = UUID(); retryBlocked = false; acknowledgedFile = nil
    }
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
      if retry { self.retryBlocked = false }
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
    guard deliveryToken == nil, !retryBlocked else { return }
    if let ack = acknowledgedFile {
      if ack.owner == generation && identity(ack.url) == ack.identity {
        do {
          #if IOS_MEMORY_TESTING
          try beforeDelete?()
          #endif
          try FileManager.default.removeItem(at: ack.url)
        } catch { retryBlocked = true; return }
      }
      acknowledgedFile = nil
    }
    guard let directory = sharedStateStore.eventQueueDirectory(),
      let file = oldestFile(in: directory) else { return }
    guard let fileIdentity = identity(file),
      let event = try? String(contentsOf: file, encoding: .utf8), !event.isEmpty else {
      // Invalid/unreadable critical files are never silently deleted. Preserve
      // order; explicit retry can resume after the storage fault is repaired.
      retryBlocked = true
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
        guard delivered else { self.deliveryToken = nil; self.retryBlocked = true; return }
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
  var beforeLocalWrite: (() -> Void)?
  func flush() { worker.sync {} }
  func testInFlight() -> Int { worker.sync { deliveryToken == nil ? 0 : 1 } }
  #endif
}
