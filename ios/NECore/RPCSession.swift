import Foundation

// Versioned, process-independent mailbox contract. Unknown/legacy bytes are
// deliberately not executed. NE alone mints the attempt before cold setup;
// startup publishes not-ready, server flips the same attempt to ready before
// accepting requests / OS completion. Stop/failure is terminal (retired).
enum RPCWire {
  static let version = 1
}

struct RPCSession: Codable, Equatable {
  let version: Int
  let attempt: UUID
  let ready: Bool
  let retired: Bool?

  init(version: Int, attempt: UUID, ready: Bool, retired: Bool = false) {
    self.version = version; self.attempt = attempt; self.ready = ready; self.retired = retired
  }

  static func read(from root: URL?) -> RPCSession? {
    guard let session = readPublished(from: root), session.ready else { return nil }
    return session
  }

  static func readPublished(from root: URL?) -> RPCSession? {
    guard let root,
      let data = try? Data(contentsOf: root.appendingPathComponent("core-rpc/session.json")),
      let session = try? JSONDecoder().decode(RPCSession.self, from: data),
      session.version == RPCWire.version, session.retired != true
    else { return nil }
    return session
  }

  @discardableResult
  func publish(to root: URL?) -> Bool {
    guard let root else { return false }
    let directory = root.appendingPathComponent("core-rpc", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
      return true
    } catch { return false }
  }
}

// nonce is per admission, not the reusable logical method-call ID/hash.
struct RPCOwner: Codable, Equatable {
  let attempt: UUID
  let generation: UInt64
  let nonce: UUID
}

struct RPCRequest: Codable {
  let version: Int
  let owner: RPCOwner
  let deadline: Date
  let data: Data
}

struct RPCReply: Codable {
  let version: Int
  let owner: RPCOwner
  let data: Data
}

struct RPCAppliedReceipt: Codable {
  let version: Int
  let owner: RPCOwner
  let requestID: String
}

// Synchronous invalidation avoids an actor-message ordering race with a new
// send. Polling terminates an old await even if the native callback never fires.
final class RPCClientEpoch: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0
  func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
  func isCurrent(_ expected: UInt64) -> Bool { current() == expected }
  func invalidate() { lock.lock(); defer { lock.unlock() }; value &+= 1 }
}

struct ProviderOwner {
  let clientEpoch: UInt64
  let attempt: UUID?
}
