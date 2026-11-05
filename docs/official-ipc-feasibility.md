# Official public ProviderMessage feasibility test (isolated branch)

This is not a VPN fix and does not move configuration or resources into NE.
Normal connect/start/stop, protocol implementations, DNS, mailbox RPC, permissions,
signing, bundle identifiers, Tg shim and core gitlinks are unchanged.

## Deliberate device experiment

1. Use normal connection once to establish the existing system VPN profile. The
   test refuses missing/ambiguous profiles; it never creates or saves a manager.
2. Do not test during working VPN traffic. In Logs tap **测试官方 IPC** and confirm.
   iOS may launch the provider or change its status for a public message. The
   experiment itself never starts/stops VPN, changes On Demand, or fakes startup.
3. The result shows before/after numeric NEVPNStatus and bounded observed status
   events, elapsed time, Runner/provider image UUID, fixed source identity, and
   boolean nonce/known-receipt validation. Export Logs retains a Runner-local
   current experiment snapshot even when the shared group directory is missing.
4. `echo_verified` proves this message round trip only. `nil_response` is not
   proof the extension never executed. `timeout`, `transport_error`, `mismatch`,
   and `profile_unavailable` are separate failures. No automatic retries.

The fixed binary request is a reserved magic, version 1 and random 16-byte UUID.
The response contains the identical request bytes, fixed known receipt and the
provider Mach-O image UUID. Both are below 4 KiB. No nonce/raw payload, credentials,
paths, arbitrary actions or raw error descriptions are persisted/exported. The
NE intercept runs before Core/lifecycle handling. Nonmatching data follows the
byte-equivalent original handler tail. Reserved malformed messages return nil
without invoking Core. The dedicated public NETunnelProviderSession path never
uses ProviderMessageBridge or filesystem mailbox fallback. One in flight, absolute
8-second deadline including manager load, exactly-once completion and generation
checks prevent late responses from overwriting a newer experiment.

## Required evidence before IPA acceptance

`python3 scripts/test_ios_official_ipc.py` validates source/fallback/slice manifests.
`python3 scripts/test_ios_official_ipc_swift.py --output <proof-dir>` is mandatory
inside the existing required macOS startup-diagnostics job, upstream of IPA build.
It compiles the actual immutable a64057e handler slice and requires the named
semantic RED (not a compiler failure); then compiles the exact candidate helper,
Runner transport methods and handler slice for all listed cases. Only Apple
framework/native Core boundaries and fixture UserDefaults/bundle are doubled.
All source/slice/compiled hashes and real compiler/runtime output are preserved in
`FlclashYF-official-ipc-proof`, including on failure. Existing required jobs and
proof artifacts remain. Windows returns **2 BLOCKED_MACOS_NOT_RED**, never PASS.

Cases: handler echo before Core, unrelated original fallback, malformed/version/
oversize/nil completion; public-session echo, observed OS status change, nil,
wrong nonce/receipt/oversize/malformed response, sanitized error, no profile,
one-inflight, response timeout, held-load timeout, late callback and new generation.
Dart export is tested by the existing isolated production export gate plus an
explicit official-IPC snapshot/no-shared-directory regression.

A signed test IPA on the actual iPad remains mandatory. Native boundary doubles
cannot prove cross-process Apple IPC under this signer. If real public IPC is
unreliable, invalidate this architecture route and stop expansion. A successful
probe is not evidence of functioning TUN, complete offline resources, atomic NE
configuration snapshots or a repaired VPN.
