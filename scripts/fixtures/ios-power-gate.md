# iOS power native gate — real macOS RED/GREEN verified

Baseline is fixed to `e502b9ce2b18bfebba550495f568f7f61e64f3da` (object must exist).
Windows preparation and Python tests are **not** native semantic evidence.
The dedicated native probe first observed exact baseline RED before production
edits, then executed independent P02/count acceptance and full P02/P03 acceptance.
See the owner report under the parent audit root for pinned runs and source hashes.

## macOS required-job entry points (Python 3 standard library + Apple swiftc)

Use a fresh evidence directory for each invocation. Do not use `--prepare-only`
or `--observe-only` as the required candidate acceptance command.

```sh
# First establish the real baseline behavior before implementing a fix:
python3 scripts/run_ios_power_gate.py --observe-only --output "$RUNNER_TEMP/ios-power-red"
python3 scripts/run_ios_power_gate.py --count-only --observe-only --output "$RUNNER_TEMP/ios-count-red"

# After implementing independently reviewed minimal fixes:
python3 scripts/run_ios_power_gate.py --output "$RUNNER_TEMP/ios-power-red-green"
python3 scripts/run_ios_power_gate.py --count-only --output "$RUNNER_TEMP/ios-count-red-green"
```

The normal gate compiles complete production declarations twice: baseline bytes
from `git show`, then candidate working-tree bytes. Source and generated SHA256,
explicit counter/boundary transformations, compile command/output, and native
structured results are retained. No regex implements or predicts native behavior.
`result.json` is the artifact; `native_acceptance` must be true for acceptance.
Candidate HEAD and dirty status are retained; a release caller should run on its
pinned clean candidate checkout and preserve this JSON with the artifact.

- Exit 0 normal run: exact baseline RED **and** candidate GREEN, including safety.
- Exit 0 prepare: PREPARED_NOT_NATIVE_VERIFIED, `native_acceptance=false`.
- Exit 0 observe: baseline RED only, `native_acceptance=false`.
- Exit 1: unexpected baseline/candidate semantic outcome (unchanged candidate fails).
- Exit 2: macOS/Swift unavailable, BLOCKED, never RED.
- Exit 3: compiler, crash/output protocol, timeout, source drift, or harness error;
  never RED. A compile failure means the fixture needs repair on Mac first.

## Production tests and boundaries

### P02: diagnostic ingress operation counts

Full `SwitchDiagnostics.record`, task_info footprint sampler, JSON serialization,
privacy filter, rotation and file append remain real. Only the container/bundle
boundary changes; exact-line insertions count executed operations.

1400 records = 100 logical ticks × two methods × seven stage names. This drives
the **real record ingress** but deliberately does not claim to execute the entire
Runner-to-NE seven-call chain or measure production cadence. Stages are taken
from source: core begin/reply, provider begin/send/reply, NE received/reply.
The candidate budget is at most 28 footprint/encode/append operations for this
burst and a maximum 2.2s wait to flush. Baseline must fail exactly those three
budget assertions, after loss/duplicate accounting passes.

Candidate aggregation must preserve counts for each method/stage in JSON lines
with event `rpc_stats_summary`, `method`, and numeric `counts` keyed by original
stage name. Loss or duplicate is a different failure, not the accepted RED.
The implementation flushes after 1s, caps attribution keys at 16, and preserves
method/stage counts plus safe route/attempt/generation attribution. Successful
routine traffic stays detailed for 10s around lifecycle/config/route changes;
errors, nil responses and config requests remain synchronous.

`diagnostic-safety` independently checks failure/start/switch/config records,
request/parent/attempt/generation correlation, nil-response retention and secret
field rejection. It must pass on baseline and candidate. Do not coalesce errors,
configuration operations, or all arbitrary methods. Production normal-rate
throttle/summary design must additionally be bounded in key/cardinality and time;
this fixture is a burst assertion, not a comprehensive sustained-memory proof.

### P03: real Dispatch timer, file mailbox and Darwin notifications

Full server, RPCSession and shared-state declarations execute. Native function
entry counters observe timer firings, drain/prune, actual contentsOfDirectory
call sites, observer add/remove and Darwin callback. No virtual clock or replaced
mailbox algorithm. After initial drain, 4.2s idle budgets are timer ≤6, prune ≤1,
directory enumerations ≤9. Baseline must fail exactly these three budgets.
These are operation budgets, not a mandated comprehensive mailbox redesign.

Safety checks run separately on both trees: failed session publication; duplicate
start and live foreign-attempt rejection; cold valid backlog and old/expired/
>125s rejection; old-orphan cleanup; reply owner/generation/nonce; intentionally
missing notification with ≤1.8s reliable fallback; observed real Darwin callback
and fast reply; stop with no timer/scans; restart and same filename with a stale
callback preceding the new callback; real 31s held setupConfig response with a
120s deadline; applied receipt owner; terminal retired session; balanced observers.
The real 31s wait checks the historical >30s server-deadline hazard. It does not
claim a full 120s boundary/device ruleset test. The fixture ran on macOS,
including real Darwin notification delivery. The candidate retains immediate
Darwin drains, a 1s missed-notification fallback (below the shortest 8s client
read deadline), and initial plus 30s monotonic orphan maintenance. Stop/restart
resets maintenance without changing admission, owner, token or deadlines.

### Independent getConnectionsCount coordination

Three hardcoded classifications are now native-verified:
`RuntimeStateCoreMethod` (NE errors must not App-fallback),
`ProviderReadRetry.isReadOnlyMethod`, `SwitchDiagnostics.methods`.
Production changes followed real native baseline RED. `--count-only` compiles
full production router/coordinator/retry/diagnostics with a transport boundary
double, requiring exact baseline RED per classification and no-fallback case,
then candidate GREEN. Success integer 123 must pass unchanged; failure must not
call App core; original count-only bytes must be forwarded once without requesting
getConnections. The real TunnelController is *not* executed in this fixture,
so ordinary lane, lease/epoch/nonce, retry timing and deadlines are not claimed
verified here. Existing real-controller attempt/review gates remain unchanged
and required. Do not add count to AppCoreMethod or ConfigurationCoreMethod.

## Deliberately excluded

P04 40ms response polling and P05 critical event backlog complexity are recorded
only, not changed. NativeResourceHeartbeat, low-memory/GC policy, Go/Dart, wire,
App Group/signing identity and all existing gate assertions are intact. Only the
isolated probe branch has CI-only trigger exclusions and its native workflow;
these workflow commits are not intended for integration cherry-pick.
The prior audit's eleven native declaration fixture and actor slice are evidence
preparation, not proof of native execution: its Windows execution exits 2.
Device energy, thermal and background suspension behavior remain separate gates.

## Portable harness-only check

```sh
python scripts/test_ios_power_gate.py
```

Checks baseline extraction, full declarations and counter seam preparation,
source-drift refusal, and strict structured result parsing. These checks cannot
validate Swift syntax or production semantics. If Mac compile fails, repair only
the test harness and rerun before implementing product changes.
