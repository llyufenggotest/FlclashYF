# Startup control transport candidate

- Immutable base: `8f0875977c1ca6a8c35c2ba61159137bf0a507fb`.
- `StartupEnvelope` carries only version 1, UUID revision and a bounded allowlisted VPN control dictionary (32 KiB total). SetupParams actually contains selected-map and test-url; both stay on the existing private shared-state path, not system preferences. The envelope never contains a home path, YAML, subscription or core resource.
- Runner validates before committing shared defaults, saves the envelope in the managed `NETunnelProviderProtocol.providerConfiguration`, reloads and checks the same revision, and passes identical bytes in manual start options. Existing request-generation guards surround preference/DNS awaits. OnDemand sync persists the current validated envelope without changing the existing OnDemand enable policy.
- Receiver validates explicit persisted and manual values. A manual value requires matching persisted revision AND options. Invalid explicit state fails closed; only both absent selects the unchanged legacy defaults decoder. Unknown versions and oversized values cannot silently choose stale defaults.
- OS NSError diagnostic codes 200–209 preserve the first VPN-options receive subreason; codes 300–303 preserve later core-setup/config/home classification. Writer and export-reader independently allowlist receive_reason and receive_source. No payload/revision digest/path/SSID is printed. UUID revision is a control receipt, not a credential digest.

## Required execution

`startup-diagnostics-native` in `ios-five-protocol.yaml` now additionally runs:

```
python3 scripts/test_ios_startup_transport.py
python3 scripts/test_ios_startup_transport_swift.py --output "$RUNNER_TEMP/startup-transport"
```

The new gate compiles immutable production provider and candidate provider plus their real shared store, manager and coordinator; it requires baseline manual/cold failure at the exact pre-settings assertion, never compiler failure. Candidate modes exercise validation/privacy/export/archived NSError, manual/cold with absent defaults, legacy, stale override, legacy closed reasons, sender revision/save-boundary checks and stop/late-settings cleanup. Framework preference calls remain boundary doubles, NOT Apple XPC tests. Original startup/iPad/DNS/restart/power/error gates remain required. Source manifests bind byte hashes; proof is nested in the existing startup artifact. The IPA job still depends on all original required jobs and builds complete Runner/NECore targets. New source has explicit membership in both.

## Honest limits / next device acceptance

Windows has no Swift/Xcode; local native gate exit 2 is BLOCKED, never native RED/GREEN or device acceptance. Native compile and baseline semantic RED are pending macOS. The bounded candidate fixes the official options transport, not the shared filesystem. Existing SetupParams defaults, app-group home-dir, config.yaml, full prepared rules/resources admission, core rollback, mailbox owner and 5-second start deadline remain unchanged. Distinct process filesystem identities have not been disproved and no alternative shared snapshot was invented. A later quickSetup failure now reports config_unreadable/home_unavailable/setup_decode/core_setup_rejected through the existing OS bridge without substituting missing config or declaring connected. Only a device showing validated receipt, completed core/TUN, running heartbeat and real traffic can close that acceptance criterion.
