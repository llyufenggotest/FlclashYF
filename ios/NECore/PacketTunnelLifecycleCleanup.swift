import Foundation

/// Idempotent cleanup for resources acquired during Packet Tunnel startup.
///
/// Startup can fail after any individual resource has been acquired. Keeping
/// the teardown in one guarded object makes every failure path safe to call,
/// including a later stopTunnel callback.
final class PacketTunnelLifecycleCleanup {
  private let lock = NSLock()
  private var cleanedUp = false
  private let actions: [() -> Void]

  init(actions: [() -> Void]) {
    self.actions = actions
  }

  func cleanup() {
    lock.lock()
    guard !cleanedUp else {
      lock.unlock()
      return
    }
    cleanedUp = true
    lock.unlock()

    for action in actions {
      action()
    }
  }
}
