import Foundation

enum ProviderReadRetry {
  static let maxAttempts = 6
  static let backoffNanoseconds: [UInt64] = [
    300_000_000,
    700_000_000,
    1_500_000_000,
    2_500_000_000,
    4_000_000_000,
  ]

  static func shouldRetry(code: String) -> Bool {
    switch code {
    case "empty_response_retryable",
      "network_extension_unavailable",
      "network_extension_timeout":
      return true
    default:
      return false
    }
  }

  static func isReadOnlyMethod(_ method: String) -> Bool {
    switch method {
    case "getProxies",
      "getTraffic",
      "getTotalTraffic",
      "getConnections",
      "getExternalProviders",
      "getExternalProvider",
      "getOverlayNetworkStatus",
      "pingTailscaleNode",
      "getMemory",
      "getGoroutineCount",
      "asyncTestDelay":
      return true
    default:
      return false
    }
  }

  static func backoff(after attempt: Int) -> UInt64 {
    backoffNanoseconds[
      min(max(attempt - 1, 0), backoffNanoseconds.count - 1)
    ]
  }
}
