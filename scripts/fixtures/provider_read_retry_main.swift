import Foundation

func check(_ condition: Bool, _ message: String) {
  if !condition { fatalError(message) }
}

check(ProviderReadRetry.maxAttempts == 6, "retry count")
check(ProviderReadRetry.backoffNanoseconds.count == 5, "backoff count")
check(ProviderReadRetry.shouldRetry(code: "empty_response_retryable"), "empty reply")
check(ProviderReadRetry.shouldRetry(code: "network_extension_unavailable"), "startup")
check(ProviderReadRetry.shouldRetry(code: "network_extension_timeout"), "timeout")
check(!ProviderReadRetry.shouldRetry(code: "configuration_error"), "explicit failure")
check(ProviderReadRetry.isReadOnlyMethod("getProxies"), "read-only method")
check(!ProviderReadRetry.isReadOnlyMethod("setupConfig"), "configuration mutation")
print("IOS_PROVIDER_READ_RETRY_PASS")
