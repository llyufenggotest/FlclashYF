# App ↔ Network Extension DNS ownership handoff

Scope: App-process DNS listener ownership only. No signature, entitlement,
shim, Dart, Go, RPC mailbox, prepared-rule, or lifecycle timeout changes.
This is not a claim that the iPad `unknown 0` startup problem is solved.

## ABI contract

`CoreMessageRouter.setAppDNSListenerSuspended` invokes IOSCoreBridge directly:

- `suspendDnsListener`, `arguments: null`, actual JSON boolean result.
- `resumeDnsListener`, `arguments: null`, actual JSON boolean result.
- Missing/malformed response, numeric 1/string true, false, or non-null error
  all fail closed. These calls never go through the NE router.

Go is responsible for actual socket closure, configMu serialization and the
persistent suspension gate; Swift awaits that acknowledgement before every
actual coordinator `startVPNTunnel`, including toggle/tile controller paths.
Generation and cached connection are rechecked after awaiting.

The coordinator serializes suspend/resume operations. A delayed resume must
finish before a newer suspend can authorize start. Terminal recovery validates
request generation, status revision, and freshly loaded managed connection;
connecting/disconnecting never count as stopped. Failed recovery retains debt
for the next offline configuration admission. Initial stopped App launch stays
App-owned without an unnecessary suspend. Online setup retains the App raw
configuration phase, with App DNS suspended before either process applies it.

## Required macOS native gate

```
python scripts/test_ios_dns_handoff_swift.py --output <external-evidence-dir>
```

The gate extracts immutable `a3aa75b3b7c851caa80d9d6964158d7e5ffbb478`
production router/controller/coordinator/types/stores/server/notification source
bodies and compiles them with controlled IOSCoreBridge/NetworkExtension
boundary doubles. No production behavior bodies are replaced. Baseline must
compile and exit 1 at the exact `start crossed unreleased App DNS listener`
assertion; compiler error is exit 3, not semantic RED. Candidate runs identical
fixture bytes across held-suspend start, toggle, A-stop-B, terminal stop,
false/nil/error/numeric envelope, online/connecting apply, disconnecting timeout,
terminal restore, stale notifications, late resume and offline recovery cases.
Original five-second observation timeout is unchanged.

Windows execution returns 2 / BLOCKED_MACOS_NOT_RED. `--prepare-only` and the
portable source/harness tests are explicitly not native acceptance. Existing
startup diagnostic, restart, attempt, and error-chain assertions are retained;
only dependency-double API defaults were extended.
