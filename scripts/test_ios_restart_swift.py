"""Required macOS restart gate: immutable production RED then candidate GREEN.

Only NetworkExtension import / Logger bundle metadata are substituted. Each
phase compiles its production method bodies unchanged, with identical fixture
bytes and assertions. Windows/Linux exit 2: host tests are NOT native execution.
"""
from pathlib import Path
import hashlib
import json
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '5cadc5524e7cb2816c5b8b99dc4582dfbfe8dc47'
PATHS = ('ios/Runner/Tunnel/TunnelCoordinator.swift', 'ios/Runner/Tunnel/TunnelTypes.swift')
CASES = ('coalesced-stop-start', 'already-dispatched-stop', 'new-generation-options',
         'stale-completion', 'third-stop-and-unrelated-status',
         'restart-stop-timeout', 'dispatched-stop-timeout', 'no-debt-loop')
BASELINE_CASE = 'restart-stop-timeout'
BASELINE_FAILURE = ('FAIL RESTART restart-stop-timeout: restart reported connected '
                    'from unchanged old tunnel after stop timeout')


def adapt_source(text):
    # Boundary-only adaptation: never change a method, timeout, or state field.
    return text.replace('import NetworkExtension\n', '').replace(
        'Bundle.main.bundleIdentifier ?? "cc.chenx.flclash"', '"test.restart"')


def load_sources(baseline):
    return {path: subprocess.check_output(
        ['git', '-C', str(ROOT), 'show', f'{BASE}:{path}']).decode('utf-8')
        if baseline else (ROOT / path).read_text(encoding='utf-8') for path in PATHS}


def run_phase(directory, swift, baseline):
    label = 'immutable-red' if baseline else 'candidate-green'
    directory = directory / label
    directory.mkdir()
    sources = load_sources(baseline)
    print(json.dumps({'phase': label, 'base': BASE if baseline else None,
                      'production_sha256': {p: hashlib.sha256(t.encode()).hexdigest()
                                            for p, t in sources.items()} }), flush=True)
    files = []
    for path, text in sources.items():
        target = directory / Path(path).name
        target.write_text(adapt_source(text), encoding='utf-8')
        files.append(str(target))
    fixture = ROOT / 'scripts/fixtures/ios_restart_main.swift'
    mainfile = directory / 'main.swift'
    mainfile.write_bytes(fixture.read_bytes())
    print(f'fixture_sha256={hashlib.sha256(mainfile.read_bytes()).hexdigest()}', flush=True)
    binary = directory / 'restart'
    command = [swift, '-swift-version', '5', *files, str(mainfile), '-o', str(binary)]
    print('COMPILE ' + json.dumps(command), flush=True)
    compile_result = subprocess.run(command, timeout=120)
    if compile_result.returncode:
        print(f'FAIL {label}: compiler failure is NOT semantic RED', flush=True)
        return 3
    for case in (BASELINE_CASE,) if baseline else CASES:
        result = subprocess.run([str(binary), case], capture_output=True, text=True, timeout=20)
        print(result.stdout, end='', flush=True)
        print(result.stderr, end='', flush=True)
        if baseline:
            if result.returncode != 1 or BASELINE_FAILURE not in result.stdout.splitlines():
                print('FAIL: exact immutable baseline semantic RED not established', flush=True)
                return 1
            print(f'CONFIRMED immutable {BASE} semantic RED (not acceptance)', flush=True)
        elif result.returncode != 0 or f'PASS RESTART {case}' not in result.stdout.splitlines():
            print(f'FAIL: candidate case {case}; exit={result.returncode}', flush=True)
            return 1
    return 0


def main():
    swift = shutil.which('swiftc')
    if platform.system() != 'Darwin' or not swift:
        print('NOT EXECUTED: production Swift restart RED/GREEN requires macOS swiftc; exit 2')
        return 2
    try:
        # Honor TMPDIR: local execution/evidence stays on the explicitly selected disk.
        with tempfile.TemporaryDirectory(prefix='ios-restart-') as directory:
            directory = Path(directory)
            red = run_phase(directory, swift, True)
            if red:
                return red
            green = run_phase(directory, swift, False)
            if green:
                return green
        print(f'PASS RESTART GATE: immutable RED then {len(CASES)} candidate behavior cases', flush=True)
        return 0
    except (subprocess.SubprocessError, OSError) as error:
        print(f'FAIL RESTART GATE: execution/lookup error, never semantic RED: {error}', flush=True)
        return 3


if __name__ == '__main__':
    raise SystemExit(main())
