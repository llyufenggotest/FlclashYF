"""Real macOS Swift/ObjC review slices. Missing Apple toolchain exits 2.
Immutable baseline snapshots are exact git blobs (manifest), not a model.
"""
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
SOURCES = ['ios/NECore/NativeDiagnosticLog.swift', 'ios/NECore/NativeResourceHeartbeat.swift',
           'ios/NECore/NECoreEventQueue.swift', 'ios/NECore/NativeStopCompletion.swift',
           'ios/Runner/Core/CoreEventRelay.swift']

def run(command, **kwargs):
    print('RUN:', ' '.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, timeout=120, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--require-swift', action='store_true')
    parser.add_argument('--baseline-native', action='store_true')
    args = parser.parse_args()
    swift, clang = shutil.which('swiftc'), shutil.which('clang')
    if platform.system() != 'Darwin' or not swift or not clang:
        print('NOT EXECUTED: Apple Swift/ObjC compile/behavior pending; no native GREEN')
        raise SystemExit(2)
    with tempfile.TemporaryDirectory(prefix='swift-review-') as name:
        temp = pathlib.Path(name)
        root = ROOT
        if args.baseline_native:
            root = temp / 'baseline'
            manifest = json.loads((FIXTURE / 'review_baseline/manifest.json').read_text())
            for path, digest in manifest['sha256'].items():
                data = (FIXTURE / 'review_baseline' / path).read_bytes()
                if hashlib.sha256(data).hexdigest() != digest:
                    raise SystemExit('Immutable baseline hash mismatch: ' + path)
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            # Header/export dependencies only, never edit baseline production.
            for path, data in {
                'libclash/ios/arm64/libclash.h': (FIXTURE / 'ios_bridge_test_exports.h').read_bytes().replace(b'"../../core/bride.h"', ('"' + str(root / 'core/bride.h') + '"').encode()),
                'core/bride.h': (ROOT / 'core/bride.h').read_bytes(),
            }.items():
                target = root / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        bridge_header = temp / 'bridge.h'
        bridge_header.write_text('#import "' + str(root / 'ios/NECore/NECoreBridge.h') + '"\n' +
            ('#import "' + str(ROOT / 'ios/Runner/IOSCoreBridge.h') + '"\n' if not args.baseline_native else '') +
            '#import "' + str(FIXTURE / 'ios_bridge_test_exports.h') + '"\n')
        objects = []
        for i, path in enumerate([root / 'ios/NECore/NECoreBridge.m', FIXTURE / 'ios_bridge_test_exports.m'] +
                                 ([] if args.baseline_native else [ROOT / 'ios/Runner/IOSCoreBridge.m'])):
            obj = temp / f'bridge{i}.o'
            run([clang, '-fobjc-arc', '-fblocks', '-DIOS_MEMORY_TESTING=1', '-c', path, '-o', obj])
            objects.append(obj)
        mainfile = temp / 'main.swift'
        mainfile.write_bytes((FIXTURE / ('ios_swift_review_baseline.swift' if args.baseline_native else 'ios_swift_review_main.swift')).read_bytes())
        if args.baseline_native:
            cases = [('M01', 'BASELINE_LOG', ['ios/NECore/NativeDiagnosticLog.swift']),
                     ('M02', 'BASELINE_BRIDGE', []),
                     ('M03', 'BASELINE_RUNNER', ['ios/Runner/Core/CoreEventRelay.swift'])]
        else:
            cases = [('GREEN', 'REVIEW_GREEN', SOURCES)]
        for label, define, sources in cases:
            binary = temp / label
            # Runner baseline uses Swift bridge dependency double to avoid a
            # duplicate imported IOSCoreBridge; NE ObjC is still linked for M02.
            run([swift, '-swift-version', '5', '-D', 'IOS_MEMORY_TESTING', '-D', define,
                 '-import-objc-header', bridge_header, *[root / p for p in sources], mainfile,
                 *objects, '-framework', 'Foundation', '-o', binary])
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            print(result.stdout, end='', flush=True)
            print(result.stderr, end='', flush=True)
            if args.baseline_native:
                if result.returncode != 1 or f'EXPECTED_REVIEW_RED {label}' not in result.stdout:
                    raise SystemExit(f'Native {label} RED not established: exit={result.returncode}')
            elif result.returncode != 0:
                raise SystemExit(result.returncode or 1)
        print('CONFIRMED expected baseline native RED (not product acceptance)' if args.baseline_native else
              'PASS native Swift/ObjC review slices; M04/Provider/device acceptance not claimed')

if __name__ == '__main__':
    main()
