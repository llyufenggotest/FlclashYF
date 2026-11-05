# 0.9.8 + main app/wrapper integration

Base: `a64057ef534c00ca1c22d9e646018ba1c90f96dd`.
Donor: immutable `f01319db13c8e1c41da70b4565b63d428d0b9c3e`.

## Actual upstream release features

v0.9.8 (`c24102a4`): sniffer override configuration UI, localization, JSON/generated models and profile generation; clear-DNS-cache method through Dart controller/interface/Go dispatch and query page; TUN authorization failure resets the toggle and authorization state; Windows installer restores a previously registered helper; picker/loading/null-status/UI fixes; Linux PNG packaging; Rust 1.99.1 toolchain. Dependencies follow the merged lockfile while preserving custom dependencies and release tooling. Flutter/Go/NDK remain canonical 3.47.7/1.26.10/r30.

## Two post-release main features (not mislabeled v0.9.8 release contents)

* `abc6fbc2`: Android selected-underlying-network changes propagate Kotlin -> exact JNI target -> exported Go wrapper -> tailscale netmon. Existing DNS update serialization remains. Network identity/gateway dedup avoids redundant notifications. Donor temporary YuliZheng tailscale replacement retained and pinned.
* `f01319db`: IPv6 and external-controller dashboard quick toggles, widget registry/localization and backward-compatible saved configuration serialization. External-controller enable binds loopback, not wildcard.

## Deliberate conflict decisions

Retained the stronger preexisting committed groups owner/generation implementation, not upstream's weaker `_coreProfileId`/`groupsProfileId` variant. Retained existing zero-baseline chart behavior. Kept private updater/workflow/signing/platform package identity; all startup envelope, ConfigAccess, mailbox, MRS, DNS ownership, low-memory, GeoXZ, power and private protocol code outside donor feature intersections is untouched. No f48/f11 experiment was merged.

Parent index keeps `core/mihomo` at accepted `d434807f7c29b30abe04f847f9df4ae492494b73`; nested core is another writer's working tree and is NOT staged by this app writer. Parent must pin its completed committed core separately. `core/sing-shadowsocks2` is unchanged.

## Added hard gates

* `scripts/test_upgrade098_semantics.py`: source ABI, runtime-only iOS classification, Windows installer ordering and CI wiring.
* `core/upgrade098_rpc_test.go`: actual `clearDnsCache` Go RPC dispatch target with null arguments and structured result (included by required wrapper `go test ./...`).
* `scripts/run_android_network_jni_gate.py`: extracts and compiles exact production JNI entrypoint against actual JNI headers; executes argument forwarding and empty-network calls; swapped-argument compiled mutation must fail. Only Go/string framework boundaries doubled. This is not an Android/device binary test.
* `test/upgrade098_semantics_test.dart`: actual profile generation preserving custom sniffer/DNS/private fields with override on/off, old saved JSON and quick-toggle roundtrip.
* `test/release_yf098_literal_test.dart`: exact `v0.9.8-yf.1` release identity.
* iOS production error-chain Swift fixture `clear-dns-routing`: runtime-only clear cache must not retry App when NE transport fails. It is explicitly required by the existing native macOS gate; local Windows only prepares sources.
* CI explicitly invokes added Dart/source/JNI gates, TUN authorization tests, and zero-baseline tests. Existing required gates and deadlines are unchanged.

## Local evidence and remaining limits

Repository-external `../app-evidence/` holds exact commands/results. Fresh Rust 1.99.1 `cargo build --locked` from candidate sources succeeded; input hashes and DLL hash are recorded, no borrowed DLL. Focused Flutter on 3.47.7: five files / 41 visible tests PASS (sniffer, RPC Dart target, quick toggles, literal release). Full Dart format gate PASS. Source semantics 4 PASS, toolchain alignment PASS, iOS DNS portable source/harness 6 PASS, Swift review source PASS; native Swift sources prepared only. Exact JNI target plus swapped-argument mutation PASS.

An initial 12-file Flutter batch hit its fixed 300-second budget after a corrected test typo; a subsequent owner/bootstrap/TUN/chart batch also hit 300 seconds during compilation, with no semantic assertion failure observed. It is NOT a passing regression batch; parent must run its final full manifest with existing fixed budgets. Candidate Go wrapper seam testing did not complete in the local bounded attempt (compilation/module preparation against concurrent core writer); parent must run completed immutable core + wrapper default/low-memory required suites. macOS Swift actual execution and five-platform packaging remain platform CI acceptance, never inferred from Windows preparation. No push, tag, dispatch or Release action is performed by this writer.
