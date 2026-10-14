#!/usr/bin/env bash
# Run on a real macOS CI runner with Dart 3.13.2 in PATH.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'Real macOS required'; exit 1; }
repo="$(git rev-parse --show-toplevel)"
baseline=348121614d7b0000db07202ec99443df24c3e2c9
scratch="$(mktemp -d "${TMPDIR%/}/profile-artifacts-gate.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/lib/common" "$scratch/test/common"
git -C "$repo" show "$baseline:lib/common/profile_artifacts.dart" > "$scratch/lib/common/profile_artifacts.dart"
cp "$repo/test/common/profile_artifacts_lock_contract.dart" "$scratch/test/common/"
set +e
dart "$scratch/test/common/profile_artifacts_lock_contract.dart" --require-macos --isolates-only > "$scratch/red.log" 2>&1
red=$?
set -e
python3 - "$scratch/red.log" "$red" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
print(text)
assert int(sys.argv[2]) != 0, 'Baseline unexpectedly passed; no genuine POSIX RED'
match = re.search(r'lockActive maximum=(\d+) final=', text)
assert match and int(match.group(1)) > 1, 'Baseline did not prove overlapping critical sections'
PY
dart "$repo/test/common/profile_artifacts_lock_contract.dart" --require-macos
dart analyze "$repo/lib/common/profile_artifacts.dart" "$repo/test/common/profile_artifacts_lock_contract.dart"
printf '%s\n' 'PASS immutable-baseline POSIX RED -> candidate GREEN on real macOS'
