"""Fail-closed macOS production Swift ACK-retry behavior gate. No source PASS."""
import argparse
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'scripts/fixtures'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-native', action='store_true')
    parser.add_argument('--require-swift', action='store_true')
    args = parser.parse_args()
    baseline = FIXTURE / 'ack_retry_baseline/CoreEventRelay.swift'
    manifest = json.loads((baseline.parent / 'manifest.json').read_text())
    if hashlib.sha256(baseline.read_bytes()).hexdigest() != manifest['sha256']:
        raise SystemExit('Immutable ACK retry baseline hash mismatch')
    if platform.system() != 'Darwin' or not shutil.which('swiftc'):
        print('NOT EXECUTED: macOS Swift ACK_RETRY native RED/GREEN pending (exit 2); source gates are not native acceptance')
        raise SystemExit(2)
    source = baseline if args.baseline_native else ROOT / 'ios/Runner/Core/CoreEventRelay.swift'
    with tempfile.TemporaryDirectory(prefix='ack-retry-') as directory:
        temp = pathlib.Path(directory)
        mainfile = temp / 'main.swift'
        mainfile.write_bytes((FIXTURE / 'ack_retry_main.swift').read_bytes())
        binary = temp / 'ack-retry'
        modes = ['ACK_RETRY_BASELINE'] if args.baseline_native else ['ACK_RETRY_AUTOMATIC', 'ACK_RETRY_CONTROLLED']
        for mode in modes:
            command = ['swiftc', '-swift-version', '5', '-D', 'IOS_MEMORY_TESTING', '-D', mode,
                       str(source), str(mainfile), '-framework', 'Foundation', '-o', str(binary)]
            print('RUN:', ' '.join(command), flush=True)
            subprocess.run(command, check=True, timeout=120)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            print(result.stdout, end=''); print(result.stderr, end='')
            if args.baseline_native:
                if result.returncode != 1 or 'FAIL ACK_RETRY: ACK=false never automatically recovered' not in result.stdout:
                    raise SystemExit('Expected compiled ACK retry RED not established')
                print('CONFIRMED immutable candidate native RED; not product acceptance')
            elif result.returncode != 0 or 'PASS ACK_RETRY real production Swift' not in result.stdout:
                raise SystemExit(result.returncode or 1)

if __name__ == '__main__':
    main()
