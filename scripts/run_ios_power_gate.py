#!/usr/bin/env python3
"""Production Swift operation-count gate; no compiler/compile error is RED.

Exit 0: native baseline semantic RED + candidate GREEN (or explicit observe).
Exit 1: semantic gate failed; 2: unsupported/missing native tools; 3: harness,
compiler, timeout, or source-seam error. --prepare-only never proves native PASS.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys

BASELINE = 'e502b9ce2b18bfebba550495f568f7f61e64f3da'
ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['ios/NECore/RPCSession.swift', 'ios/NECore/PacketTunnelSharedStateStore.swift',
           'ios/NECore/PacketTunnelCommandServer.swift', 'ios/Shared/SwitchDiagnostics.swift',
           'ios/Shared/ProviderReadRetry.swift']
REDS = {
    'p02': ['p02_footprint_budget', 'p02_json_encode_budget', 'p02_append_budget'],
    'p03': ['p03_idle_timer_budget', 'p03_idle_prune_budget', 'p03_idle_enumeration_budget'],
}
# These counters observe real executed operations; they do not decide behavior.
SEAMS = {
    'ios/Shared/SwitchDiagnostics.swift': [
        ('  private static func footprintMB() -> Double {', '    PowerProbe.bump("footprint")'),
        ('      guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),', '      PowerProbe.bump("json_encode")'),
        ('  private static func append(_ data: Data, to url: URL) throws {', '    PowerProbe.bump("append")'),
    ],
    'ios/NECore/PacketTunnelCommandServer.swift': [
        ('  private func drain() {', '    PowerProbe.bump("drain")'),
        ('  private func pruneOrphans() {', '    PowerProbe.bump("prune")'),
        ('      timer.setEventHandler { [weak self] in', '        PowerProbe.bump("timer")'),
        ('    CFNotificationCenterAddObserver(', '    PowerProbe.bump("observer_add")'),
        ('    CFNotificationCenterRemoveObserver(', '    PowerProbe.bump("observer_remove")'),
        ('    let server = Unmanaged<PacketTunnelCommandServer>', '    PowerProbe.bump("notification")'),
        ('    guard let files = try? FileManager.default.contentsOfDirectory(', '    PowerProbe.bump("enumerate")'),
        ('      guard let files = try? FileManager.default.contentsOfDirectory(', '      PowerProbe.bump("enumerate")'),
    ],
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def checked(command, *, timeout=180):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    return {'command': command, 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def source_bytes(repo, rel, ref=None):
    if ref:
        return subprocess.check_output(['git', '-C', str(repo), 'show', f'{ref}:{rel}'])
    return (repo / rel).read_bytes()


def instrument(raw, rel, unique):
    text = raw.decode('utf-8')
    changes = []
    # Explicit application boundary replacements only. Full declarations retained.
    for old, new in [('Bundle.main.bundleIdentifier!', json.dumps(unique + '.NECore')),
                     ('FileManager.default.containerURL(', 'PowerBoundary.containerURL(')]:
        if old in text:
            changes.append({'kind': 'boundary', 'old': old, 'new': new, 'matches': text.count(old)})
            text = text.replace(old, new)
    for anchor, counter in SEAMS.get(rel, []):
        # Exact *line* match, not substring/regex; indentation distinguishes two enumerations.
        lines = text.splitlines(keepends=True)
        matches = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == anchor]
        if len(matches) != 1:
            raise ValueError(f'counter seam must match exactly once: {rel}: {anchor!r}; got {len(matches)}')
        i = matches[0]
        # guard/function/closure counters go before the guard or after the opening brace.
        if anchor.endswith('{'):
            lines.insert(i + 1, counter + '\n')
        else:
            lines.insert(i, counter + '\n')
        text = ''.join(lines)
        changes.append({'kind': 'observation_only', 'anchor': anchor, 'counter': counter})
    # CF types used by production rely on umbrella imports in the iOS build.
    text = 'import CoreFoundation\n' + text
    return text, changes


def prepare(repo, out, label, ref=None):
    build = out / label / 'build'
    build.mkdir(parents=True, exist_ok=True)
    manifest = []
    files = []
    unique = 'audit.power.' + label + '.' + out.name.replace('-', '')
    for rel in SOURCES:
        raw = source_bytes(repo, rel, ref)
        text, changes = instrument(raw, rel, unique)
        dest = build / Path(rel).name
        dest.write_text(text, encoding='utf-8')
        files.append(str(dest))
        manifest.append({'path': rel, 'source_sha256': sha(raw), 'compiled_sha256': sha(dest.read_bytes()),
                         'full_declaration': True, 'changes': changes})
    main = build / 'main.swift'
    main.write_bytes((ROOT / 'scripts/fixtures/ios_power_main.swift').read_bytes())
    files.append(str(main))
    (out / label / 'sources.json').write_text(json.dumps({'ref': ref or 'working-tree', 'sources': manifest,
        'fixture_sha256': sha(main.read_bytes()), 'not_replaced': ['task_info', 'Foundation I/O', 'JSON coding',
        'Dispatch timer', 'Darwin notifications', 'owner/token/deadline/receipt checks'],
        'not_covered': ['whole seven-stage RPC chain', 'device energy', 'Runner response polling', 'critical backlog']}, indent=2), encoding='utf-8')
    return files, build / 'ios-power'


def prepare_count(repo, out, label, ref=None):
    build = out / (label + '-count') / 'build'
    build.mkdir(parents=True, exist_ok=True)
    files, manifest = [], []
    paths = ['ios/NECore/RPCSession.swift', 'ios/Shared/ProviderReadRetry.swift',
             'ios/Shared/SwitchDiagnostics.swift', 'ios/Runner/Core/CoreMessageRouter.swift',
             'ios/Runner/Core/CoreNotificationCoordinator.swift']
    for rel in paths:
        raw = source_bytes(repo, rel, ref)
        text, changes = instrument(raw, rel, 'audit.count.' + label + '.' + out.name.replace('-', ''))
        dest = build / Path(rel).name
        dest.write_text(text, encoding='utf-8')
        files.append(str(dest))
        manifest.append({'path': rel, 'source_sha256': sha(raw), 'compiled_sha256': sha(dest.read_bytes()),
                         'full_declaration': True, 'changes': changes})
    main = build / 'main.swift'
    main.write_bytes((ROOT / 'scripts/fixtures/ios_power_count_main.swift').read_bytes())
    files.append(str(main))
    (out / (label + '-count') / 'sources.json').write_text(json.dumps({'ref': ref or 'working-tree',
        'sources': manifest, 'fixture_sha256': sha(main.read_bytes()),
        'boundary_doubles': ['TunnelController transport', 'IOSCoreBridge'],
        'scope': 'actual router no-fallback, integer passthrough, retry classification, diagnostics allowlist; not real controller lanes/deadline'}, indent=2), encoding='utf-8')
    return files, build / 'ios-count'


def semantic_record(result, mode):
    records = []
    for line in result['stdout'].splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get('fixture') in ['ios-power-production-v1', 'ios-power-count-v1'] and value.get('mode') == mode:
            records.append(value)
    if len(records) != 1:
        raise ValueError('missing/duplicate structured native result; crash is not RED')
    return records[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--count-only', action='store_true', help='independent getConnectionsCount route/retry/diagnostics gate')
    parser.add_argument('--observe-only', action='store_true', help='baseline metrics/RED only, never candidate acceptance')
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = {'baseline': BASELINE, 'status': 'not_executed', 'native_acceptance': False, 'executions': []}

    def save(code, status):
        report.update(status=status, exit_code=code)
        (out / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print(f'{status}; exit {code}; native_acceptance={report["native_acceptance"]}')
        return code

    try:
        # Exact baseline object must exist; never silently substitute HEAD or a model.
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', BASELINE + '^{commit}'], text=True).strip()
        if actual != BASELINE:
            raise ValueError('baseline mismatch')
        report['candidate_head'] = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        report['candidate_status'] = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True)
        prepare_fn = prepare_count if args.count_only else prepare
        cases = ['count-readonly', 'count-diagnostic', 'count-no-fallback', 'count-integer'] if args.count_only else ['diagnostic-safety', 'mailbox-safety', 'p02', 'p03']
        expected_reds = {
            'count-readonly': ['count_readonly_classification'],
            'count-diagnostic': ['count_diagnostic_allowlist'],
            'count-no-fallback': ['count_ne_failure_fell_back_to_app', 'count_ne_error_not_preserved'],
        } if args.count_only else REDS
        report['scope'] = 'getConnectionsCount wiring' if args.count_only else 'P02/P03 operation counts'
        builds = {label: prepare_fn(repo, out, label, ref) for label, ref in [('baseline', BASELINE), ('candidate', None)]}
        if args.prepare_only:
            return save(0, 'PREPARED_NOT_NATIVE_VERIFIED')
        swift = shutil.which('swiftc')
        if platform.system() != 'Darwin' or not swift:
            return save(2, 'BLOCKED_MACOS_SWIFTC_REQUIRED_NOT_RED')
        report['executions'].append(checked([swift, '--version']))
        for label in ['baseline', 'candidate']:
            if args.observe_only and label == 'candidate':
                continue
            files, binary = builds[label]
            compile_result = checked([swift, '-swift-version', '5', '-O', '-D', 'SWITCH_DIAGNOSTICS_TESTING',
                                      '-D', 'IOS_ATTEMPT_TESTING', *files, '-o', str(binary)])
            report['executions'].append(compile_result)
            if compile_result['exit_code']:
                return save(3, 'COMPILE_ERROR_NOT_SEMANTIC_RED')
            for mode in cases:
                runtime = out / label / ('runtime-' + mode)
                if runtime.exists():
                    raise ValueError(f'output runtime must be fresh, will not delete existing evidence: {runtime}')
                result = checked([str(binary), str(runtime), mode], timeout=65)
                record = semantic_record(result, mode)
                report['executions'].append({**result, 'native_record': record, 'source': label})
                if label == 'baseline' and mode in expected_reds:
                    if result['exit_code'] != 1 or record['status'] != 'semantic_failure' or record['failures'] != expected_reds[mode]:
                        return save(1, 'BASELINE_MUST_FAIL_EXACT_POWER_ASSERTIONS')
                elif result['exit_code'] != 0 or record['status'] != 'pass' or record['failures']:
                    return save(1, 'NATIVE_SAFETY_OR_CANDIDATE_ASSERTION_FAILED')
        if args.observe_only:
            return save(0, 'BASELINE_NATIVE_RED_OBSERVED_NOT_ACCEPTANCE')
        report['native_acceptance'] = True
        return save(0, 'NATIVE_BASELINE_RED_CANDIDATE_GREEN_NOT_DEVICE_ENERGY')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        report['error'] = str(error)
        return save(3, 'HARNESS_ERROR_NOT_RED')


if __name__ == '__main__':
    sys.exit(main())
