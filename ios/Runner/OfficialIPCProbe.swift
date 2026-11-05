import Foundation
import NetworkExtension

@MainActor
final class OfficialIPCProbe {
  static let shared = OfficialIPCProbe()
  private static let storageKey = "officialIPCFeasibilityV1"
  private var generation: UUID?
  private var timer: DispatchWorkItem?
  private var observer: NSObjectProtocol?
  private var connection: NETunnelProviderSession?
  private var completion: ((String) -> Void)?
  private var deadline: TimeInterval = 0
  private var started: TimeInterval = 0
  private var fields: [String: String] = [:]

  static func export() -> String {
    guard let data = UserDefaults.standard.data(forKey: storageKey), data.count <= 4096,
      let row = try? JSONDecoder().decode([String: String].self, from: data),
      row["schema"] == "official-ipc-v1" else { return "official-ipc-v1 outcome=not_run" }
    let tokens = Set(["schema", "source", "runner_image_uuid", "provider_image_uuid", "timestamp", "outcome", "nonce_equal", "known_receipt", "elapsed_ms", "status_before", "status_after", "status_events", "error_domain", "error_code"])
    let safe = row.filter { tokens.contains($0.key) && $0.value.utf8.count <= 128 && $0.value.range(of: "^[A-Za-z0-9_.:,=+ -]+$", options: .regularExpression) != nil }
    return "official-ipc-v1 " + safe.keys.sorted().map { "\($0)=\(safe[$0]!)" }.joined(separator: " ")
  }

  func run(_ completion: @escaping (String) -> Void) {
    guard generation == nil else { completion("official-ipc-v1 outcome=busy"); return }
    let token = UUID()
    generation = token
    self.completion = completion
    started = ProcessInfo.processInfo.systemUptime
    deadline = started + 8
    fields = ["schema": "official-ipc-v1", "source": "official-ipc-a64057e-v1", "runner_image_uuid": OfficialIPCWire.imageUUID(), "timestamp": ISO8601DateFormatter().string(from: Date()), "nonce_equal": "false", "known_receipt": "false", "status_before": "unavailable", "status_after": "unavailable", "status_events": ""]
    let timeout = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.finish(token, outcome: "timeout") }
    }
    timer = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.current(token) else { return }
          if let error { self.fail(token, error: error); return }
          let identifier = (Bundle.main.bundleIdentifier ?? "") + ".NECore"
          let matching = (managers ?? []).filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
          }
          guard matching.count == 1, let manager = matching.first,
            let session = manager.connection as? NETunnelProviderSession else {
            self.finish(token, outcome: "profile_unavailable"); return
          }
          self.connection = session
          self.fields["status_before"] = String(session.status.rawValue)
          self.observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
              guard let self, self.generation == token else { return }
              let value = String(session.status.rawValue)
              let prior = self.fields["status_events"] ?? ""
              if prior.count < 96 { self.fields["status_events"] = prior.isEmpty ? value : prior + "," + value }
            }
          }
          let request = OfficialIPCWire.request(nonce: UUID())
          do {
            try session.sendProviderMessage(request) { [weak self] response in
              DispatchQueue.main.async {
                MainActor.assumeIsolated {
                  guard let self, self.current(token) else { return }
                  guard let response else { self.finish(token, outcome: "nil_response"); return }
                  guard let identity = OfficialIPCWire.validate(response, request: request) else {
                    self.finish(token, outcome: "mismatch"); return
                  }
                  self.fields["provider_image_uuid"] = identity
                  self.fields["nonce_equal"] = "true"
                  self.fields["known_receipt"] = "true"
                  self.finish(token, outcome: "echo_verified")
                }
              }
            }
          } catch { self.fail(token, error: error) }
        }
      }
    }
  }

  private func current(_ token: UUID) -> Bool {
    guard generation == token else { return false }
    guard ProcessInfo.processInfo.systemUptime < deadline else { finish(token, outcome: "timeout"); return false }
    return true
  }

  private func fail(_ token: UUID, error: Error) {
    let value = error as NSError
    let domains = ["NEVPNErrorDomain", "NEVPNConnectionErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain"]
    fields["error_domain"] = domains.contains(value.domain) ? value.domain : "other"
    fields["error_code"] = String(value.code)
    finish(token, outcome: "transport_error")
  }

  private func finish(_ token: UUID, outcome: String) {
    guard generation == token else { return }
    generation = nil
    timer?.cancel(); timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    fields["outcome"] = outcome
    fields["elapsed_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
    if let connection { fields["status_after"] = String(connection.status.rawValue) }
    connection = nil
    if let data = try? JSONEncoder().encode(fields), data.count <= 4096 { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    let callback = completion
    completion = nil
    callback?(Self.export())
  }
}
