import Foundation

/// System completion is independent of main, diagnostic/event I/O and native
/// GC. Expiry completes the OS request only: it never reopens core admission.
final class NativeStopCompletion {
  private static let lane = DispatchQueue(label: "com.follow.clash.stop-completion")
  private let lock = NSLock()
  private var completion: (() -> Void)?
  init(deadline: TimeInterval = 5, completion: @escaping () -> Void) {
    self.completion = completion
    Self.lane.asyncAfter(deadline: .now() + deadline) { [self] in finish() }
  }
  func finish() {
    lock.lock()
    let callback = completion
    completion = nil
    lock.unlock()
    callback?()
  }
}
