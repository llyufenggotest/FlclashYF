#!/usr/bin/env bash
# Mandatory macOS pre-IPA gate; unsupported host is a failure, not a skip.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v swiftc
python3 scripts/test_ios_attempt_recovery.py
python3 scripts/test_ios_attempt_recovery_swift.py --baseline --require-swift
python3 scripts/test_ios_attempt_recovery_swift.py --require-swift
python3 scripts/test_ios_provider_retry.py
python3 scripts/test_ios_switch_wiring.py
python3 scripts/test_ios_lifecycle_cleanup.py
python3 scripts/test_ios_lifecycle_behavior.py
