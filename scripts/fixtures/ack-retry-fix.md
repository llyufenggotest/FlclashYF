# SWIFT_ACK_RETRY_LIVENESS only

Candidate baseline: `4cb33f08dda80bb82cbec92c789891eb849ee345`.
`ack_retry_baseline/CoreEventRelay.swift` is the exact immutable Git blob, verified by SHA256 manifest; no old review baseline or expected assertion changed.

Production relay now coalesces read/ACK=false/delete failures into one worker-owned DispatchWorkItem, with 250ms exponential backoff capped at 8s. Retry closures capture only weak relay plus owner/token, not payload. ACKed delete retries keep identity and never resend. Only successful ACK/file resolution resets failure count. reset/stop/deinit cancel retry; generation and retry token reject stale callbacks. reset/stop do not release the real Flutter delivery slot. stop is an explicit lifecycle API, not a claim of new ServiceChannel teardown integration.

## Required macOS native checks (parent owns unified CI)

```
python3 scripts/test_ios_ack_retry.py --baseline-native --require-swift
python3 scripts/test_ios_ack_retry.py --require-swift
```

First command must actually compile the immutable baseline and confirm its exit-1 `ACK=false never automatically recovered` assertion. A compiler failure is not RED. Second compiles production CoreEventRelay twice: real Dispatch scheduling verifies automatic ACK/delete recovery without another init/drain; controlled scheduling checks read recovery, notification flood coalescing, bounded permanent failures, success reset, reset/stop cancellation, hung ACK occupancy, generation/file authority, and full Unicode event preservation. Only dependencies (SharedStateStore, IOSCoreBridge) are doubled; no relay implementation model. Existing Swift/ObjC review gate remains required separately.

Windows execution returns 2 for both native commands: **native RED/GREEN pending**, never source-only acceptance. Supplemental source check rejects the original candidate and accepts this source, but does not compile or run Swift. No device/Flutter engine/Go end-to-end memory claim; no protocol/resource/Widget/shim/RPC changes.
