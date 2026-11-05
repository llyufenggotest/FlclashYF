# R1/R2 independent review follow-up

Only findings from immutable `6a95950d54b4e1fefe3507b0730ebeab95d9095c`.

- R1 removes the 256-entry list restriction, preserving list types, existing element validation, the complete 32 KiB byte budget and no truncation.
- R2 keeps full Dart VPN options in Runner-local preferences keyed by startup revision. No setup/YAML is retained there. The provider publishes the accepted revision only when it publishes active control options after startTun. Runner requires NE readback, a known local snapshot and exact control equality; unknown/missing/mismatched receipts return nil. Current desired state is never used to rebuild active history. Legacy full active JSON and the direct VpnManager caller remain unchanged.
- Snapshot retention keeps the acknowledged active and previous pending revision when preparing another revision, avoiding unbounded history. A missing/pruned receipt is not evidence of a running configuration.

`scripts/fixtures/startup_review_original.swift` is the independent review probe copied byte-for-byte (SHA256 `8b5a912e9f8b8e073db61ca0255e4aba544cb66fd7cba2ca13c0e2fb8130093c`). `.gitattributes` prevents checkout newline conversion. The original external review wrapper/probes remain untouched. New Mac gate compiles every baseline production source from 6a959, requires its three exact semantic RED assertions, then runs the same assertions against the candidate. Candidate setup changes only obtain the actual store revision and publish it through saveRunTime; assertions are not changed. Additional candidate cases cover allowBypass history, local reload, receipt absence/mismatch, stop, legacy, budget-valid 1024 routes/no truncation, invalid type/oversize, and actual production provider completion/receipt.

Required `startup-diagnostics-native` executes this gate, archives manifests/logs, and remains a dependency of IPA packaging. Windows exit 2 is BLOCKED, neither native RED nor GREEN. Framework doubles do not prove Apple cross-process delivery, system preference save/reload, or device connectivity. Existing transport/diagnostic/DNS/power/error gates remain mandatory.
