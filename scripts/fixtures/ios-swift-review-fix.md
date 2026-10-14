# Swift review fix candidate — native acceptance pending

## Scope and ownership

- Parent base: `65e6323be3a4ea435a524ae5743479660010081c`.
- Core working HEAD remains `0e8081920ce5b5c23d341ee8fd72b0099a96dca3`; do not stage its pre-existing dirty gitlink or change Go.
- This change owns M01/M02/M03 and CI01/02/03 only. M04 actual native RPC occupancy belongs to the parent and remains unresolved by this change. No total-memory-bounded claim.
- Widget behavior, protocols, full event/config payloads, rules, 120-second configuration timeout, iOS compatibility loader and entitlements are preserved.

## Changes

- Diagnostic writer: asynchronous admission with separate reserved critical (16 jobs/128 KiB) and lossy (64 jobs/256 KiB) budgets including executing writes. Diagnostic overload is counted and summarized on the writer. Diagnostic critical markers are not falsely promised lossless under unlimited overload. Production main no longer flushes disk.
- Heartbeat retirement: provider asynchronously waits for an old uncancellable GC, closes new-core admission until actual native shutdown finishes, and never treats an OS stop deadline as native retirement. A one-shot stop completion deadline is registered before main dispatch on a separate lane.
- NE events: independent ObjC event sink + process-wide one-slot admission before NSData conversion; shared RPC callback queue is not used by events. Owned generation controls admission, one worker persists a single full payload. Stop/markResponsive do not wait on event disk. Admitted payload finishes durably; transient storage failures retain that single payload and retry. Only existing all-bulk classes are prunable, never mixed or unknown events.
- Runner: separate producer/persistence and ACK-consumer workers. One ACK window, one retained oldest path through streamed directory enumeration, no per-notification Task. Files survive missing/failed ACKs. Successful ACK deletion has retry state; generation/token and file identity protect replacement files. Reset does not release a hung real Flutter occupancy.
- CI: published round2 baseline `d4f707b7ed80d1a9eb2d0de07120bb83f4e228ce`, both Go replacement submodules initialized, and required independent macOS native gate is a dependency of five-platform iOS packaging. M04 blocker confirmation is not used as product GREEN.

## Native test commands (must run on macOS)

```sh
python3 scripts/test_ios_swift_review.py --baseline-native --require-swift
python3 scripts/test_ios_memory_round2.py --baseline-native --require-swift
python3 scripts/test_ios_swift_review.py --require-swift
python3 scripts/test_ios_memory_round2.py --require-swift
python3 scripts/test_ios_heartbeat.py
python3 scripts/test_ios_lifecycle_behavior.py
```

The review runner compiles exact production Swift and both production ObjC bridges. Only generated Go C exports/app-group environment are dependencies doubled. The immutable `65e` production blobs are vendored as tiny test-only snapshots with SHA256 manifest; do not replace them with GREEN source or string-transform the implementation. The published `d4f707` regression uses git history. Missing Swift/Apple SDK exits **2**, not a test success.

Covered by prepared native slices: held diagnostic writer, main heartbeat/stop/completion liveness, held GC retirement, held event write with real ObjC RPC response unblocked, Runner held producer/RPC main liveness, ACK flood/failed retry/delete retry/late owner/reused file, full >5 MiB mixed payload and ordered 200-file drain. Existing round2 retains UTF-8, 64 MiB inherited rotation, old owner, lossy-only cap and complete critical mixed batches. These are prepared tests, **not executed behavior evidence on Windows**.

## Local evidence and remaining gates

Source-only RED at `65e`: exit 1. Candidate source gates: exit 0. Lifecycle source gates: five passed. Python syntax and `git diff --check`: passed. Snapshot bytes checked against `git show 65e` and SHA256: matched.

Windows native invocations: baseline and candidate both exit 2, `NOT EXECUTED`. Evidence is external at `F:/Temp/oix-test/evidence/flclashyf-20261014-repair/memory/swift-review-fix/`.

Required next acceptance: isolated combined-tree macOS CI compile and execution; full Xcode IPA build; device footprint/stop timing/GC and listener retirement. Do not report Swift GREEN, losslessness across Go upstream queues, or total bounded memory until those distinct gates are actually satisfied.
