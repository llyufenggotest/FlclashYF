import Foundation

/// Bounded asynchronous diagnostics. Critical has a reserved admission lane;
/// neither lifecycle nor heartbeat ever waits for log I/O. Overload is counted.
@objc(NECoreNativeDiagnosticLog)
final class NativeDiagnosticLog: NSObject {
  static let shared = NativeDiagnosticLog()
  private let queue = DispatchQueue(label: "com.follow.clash.necore-diagnostics")
  private let admissionLock = NSLock()
  private var pendingJobs = 0
  private var pendingBytes = 0
  private var droppedLogs = 0
  private var pendingCriticalJobs = 0
  private var pendingCriticalBytes = 0
  private var droppedCritical = 0
  private var reportedDrops = 0
  static let maxCriticalJobs = 16
  static let maxCriticalBytes = 128 * 1024
  static let maxPendingJobs = 64
  static let maxPendingBytes = 256 * 1024
  static let maxLineBytes = 8 * 1024
  private let maxBytes: UInt64 = 4 * 1024 * 1024
  private let fileName = "ios-necore-native.log"
  #if IOS_MEMORY_TESTING
  private var testURL: URL?
  private var beforeWrite: (() -> Void)?
  #endif

  private override init() {}

  @objc(appendCoreLogLevel:message:)
  static func appendCoreLog(level: String, message: String) {
    guard level.caseInsensitiveCompare("debug") != .orderedSame else { return }
    shared.append("core level=\(String(level.prefix(32))) message=\(sanitize(message))", discardable: true)
  }

  func append(_ message: String, discardable: Bool = false) {
    // Prefix before formatting/regex: a huge diagnostic string must not allocate
    // a second huge copy. This is a LOG-only cap, never a config/event cap.
    let bounded = String(decoding: message.utf8.prefix(4096), as: UTF8.self)
    let line = "\(ISO8601DateFormatter().string(from: Date())) [attempt=\(SwitchDiagnostics.processID)] [NECore] \(bounded)\n"
    let data = Data(line.utf8.prefix(Self.maxLineBytes - 1)) + Data([0x0A])
    admissionLock.lock()
    let admitted: Bool
    if discardable {
      admitted = pendingJobs < Self.maxPendingJobs && pendingBytes <= Self.maxPendingBytes - data.count
      if admitted { pendingJobs += 1; pendingBytes += data.count }
      else { droppedLogs = min(droppedLogs, Int.max - 1) + 1 }
    } else {
      admitted = pendingCriticalJobs < Self.maxCriticalJobs && pendingCriticalBytes <= Self.maxCriticalBytes - data.count
      if admitted { pendingCriticalJobs += 1; pendingCriticalBytes += data.count }
      else { droppedCritical = min(droppedCritical, Int.max - 1) + 1 }
    }
    admissionLock.unlock()
    guard admitted else { return }
    queue.async { [self] in
      defer {
        admissionLock.lock()
        if discardable { pendingJobs -= 1; pendingBytes -= data.count }
        else { pendingCriticalJobs -= 1; pendingCriticalBytes -= data.count }
        admissionLock.unlock()
      }
      write(data)
      // Persist a cumulative overload report on the writer itself. No extra
      // retained async closure, no infinite promise of lossless diagnostic logs.
      admissionLock.lock()
      let lossy = droppedLogs, critical = droppedCritical
      let total = min(lossy, Int.max - critical) + critical
      let changed = total != reportedDrops
      reportedDrops = total
      admissionLock.unlock()
      if changed {
        write(Data("diagnostic_overload dropped_lossy=\(lossy) dropped_critical=\(critical)\n".utf8))
      }
    }
  }

  func flush() { queue.sync {} }

  private func write(_ data: Data) {
    #if IOS_MEMORY_TESTING
    beforeWrite?()
    #endif
    guard let url = fileURL() else { return }
    do {
      try rotateIfNeeded(url: url, incomingBytes: UInt64(data.count))
      if !FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      // File-system failures cannot change tunnel or RPC outcomes.
    }
  }

  private func fileURL() -> URL? {
    #if IOS_MEMORY_TESTING
    if let testURL { return testURL }
    #endif
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: PacketTunnelEnvironment.appGroupIdentifier
    )?.appendingPathComponent(fileName)
  }

  private func rotateIfNeeded(url: URL, incomingBytes: UInt64) throws {
    let input = try? FileHandle(forReadingFrom: url)
    guard let input else { return }
    defer { try? input.close() }
    let size = try input.seekToEnd()
    guard size > maxBytes - incomingBytes else { return }
    let temporary = url.appendingPathExtension("rotation")
    // Read only the newest retained window, streaming 64KiB chunks. An oversized
    // inherited file must not be readAll'd into this constrained process.
    try input.seek(toOffset: size - min(size, maxBytes / 2))
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { return }
    let output = try FileHandle(forWritingTo: temporary)
    defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
    var foundBoundary = false
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
      if foundBoundary {
        try output.write(contentsOf: chunk)
      } else if let newline = chunk.firstIndex(of: 0x0A) {
        foundBoundary = true
        try output.write(contentsOf: chunk[chunk.index(after: newline)...])
      }
    }
    try output.close()
    // Same-directory atomic replacement preserves a complete export on failure.
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }

  /// Compatibility helper for existing tests; production rotation is streaming.
  static func retainedTail(of data: Data, limit: Int) -> Data {
    guard data.count > limit else { return data }
    let tail = data.suffix(limit)
    guard let newline = tail.firstIndex(of: 0x0A) else { return Data() }
    return Data(tail[tail.index(after: newline)...])
  }

  private static func sanitize(_ message: String) -> String {
    var value = String(decoding: message.utf8.prefix(4096), as: UTF8.self)
    for key in ["password", "token", "authorization", "private-key", "uuid"] {
      value = value.replacingOccurrences(
        of: "(?i)(\(key)\\s*[:=]\\s*)[^,\\s}]+",
        with: "$1[REDACTED]", options: .regularExpression
      )
    }
    return value
  }

  #if IOS_MEMORY_TESTING
  func setTestURL(_ url: URL, beforeWrite: (() -> Void)? = nil) {
    queue.sync { testURL = url; self.beforeWrite = beforeWrite }
  }
  func testCriticalPending() -> (jobs: Int, bytes: Int, dropped: Int) {
    admissionLock.lock(); defer { admissionLock.unlock() }
    return (pendingCriticalJobs, pendingCriticalBytes, droppedCritical)
  }
  func testPending() -> (jobs: Int, bytes: Int, dropped: Int) {
    admissionLock.lock(); defer { admissionLock.unlock() }
    return (pendingJobs, pendingBytes, droppedLogs)
  }
  #endif
}
