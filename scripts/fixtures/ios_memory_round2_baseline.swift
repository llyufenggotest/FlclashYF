// Run against immutable baseline production sources, not a Python model.
import Foundation

final class NECoreBridge { static func releaseMemory() {} }
final class NativeDiagnosticLog {
  static let shared = NativeDiagnosticLog()
  func append(_ message: String) {}
}
// Hold an actual native reclaim open and demonstrate that baseline stop returns
// while its old handler is still running. The repaired implementation drains it.
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let stopped = DispatchSemaphore(value: 0)
let heartbeat = NativeResourceHeartbeat(reclaim: {
  entered.signal()
  _ = release.wait(timeout: .now() + 10)
})
heartbeat.start()
// Baseline has no injected resource sampler. A direct production timer race
// cannot reliably reach the reclaim threshold on an arbitrary macOS host.
// The source-wiring gate establishes baseline RED; deterministic production
// sampling and stale-tick hooks are exercised by the repaired harness instead.
heartbeat.stop()
print("BASELINE: no deterministic reclaim sampler; use source RED + repaired native harness, NOT a claimed runtime RED")
