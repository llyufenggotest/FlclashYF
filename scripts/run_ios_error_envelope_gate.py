#!/usr/bin/env python3
"""Mac-only core-error detail gate. Compiler errors/timeouts are never RED."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import run_ios_power_gate as power

BASELINE = power.BASELINE
PRE_FIX = 'fa94ff59cffe7e540b2119aa3f3900517423effb'
FAILURE = ['core_error_reply_detail_coalesced']
ROOT = Path(__file__).resolve().parents[1]
# Original independent review scripts retained by digest, without importing their
# hard-coded parent paths or changing the wire/detail assertions.
ORIGINAL = {
    'prepare_error_probe.py': '81ba2cb0b6979b17841e3cacc6cabcb044ca7efa9d609910b94db5eafb016b80',
    'run_error_probe_on_mac.py': 'e4380399c9a0936ef312b334a3cf77276cec537a088744820988c74b3df8bf8c',
}

def fixture(repo):
    text = (repo / 'scripts/fixtures/ios_power_main.swift').read_text(encoding='utf-8')
    old = 'let success = Data(#"{"result":"","error":null}"#.utf8)'
    new = 'let success = mode == "error-envelope" ? Data(#"{"result":null,"error":{"code":"invalid_arguments","message":"missing arguments","details":null}}"#.utf8) : Data(#"{"result":"","error":null}"#.utf8)'
    assert text.count(old) == 1
    text = text.replace(old, new)
    anchor = 'check(mode == "mailbox-safety", "unknown_fixture_mode")'
    probe = '''if mode == "error-envelope" {
  check(server.start(attempt: attempt), "error_server_start")
  // Real production server; only Go invocation is a named boundary double.
  // Missing bool arguments produce this core invalid_arguments envelope.
  publish("core-error", owner: owner)
  check(waitUntil(2) { reply("core-error") != nil }, "error_reply_missing")
  check(reply("core-error")?.data == success, "wire_error_changed")
  check(reply("core-error")?.owner == owner, "wire_owner_changed")
  sleepMS(1500)
  let logged = rows()
  let requestID = SwitchDiagnostics.requestID(Data(#"{"method":"getTraffic","id":"core-error"}"#.utf8))
  let detailed = logged.contains { $0["event"] as? String == "rpc_reply" && $0["request_id"] as? String == requestID }
  server.stop()
  finish(detailed ? [] : ["core_error_reply_detail_coalesced"], metrics: ["rows": logged, "wire_error_preserved": true])
}
'''
    assert text.count(anchor) == 1
    return text.replace(anchor, probe + anchor).encode()

def prepare(repo, out, label, ref):
    directory = out / label
    directory.mkdir(parents=True, exist_ok=True)
    manifest, files = [], []
    for rel in power.SOURCES:
        raw = power.source_bytes(repo, rel, ref)
        text, changes = power.instrument(raw, rel, 'audit.error.' + label)
        dest = directory / Path(rel).name
        dest.write_bytes(text.encode())
        files.append(str(dest))
        manifest.append(dict(path=rel, source_sha256=power.sha(raw), compiled_sha256=power.sha(dest.read_bytes()), changes=changes))
    main = directory / 'main.swift'
    main.write_bytes(fixture(repo))
    files.append(str(main))
    (directory / 'sources.json').write_text(json.dumps(dict(ref=ref, sources=manifest, fixture_sha256=power.sha(main.read_bytes())), indent=2))
    return files, directory / 'native'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--observe-only', action='store_true')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    report = dict(baseline=BASELINE, pre_fix=PRE_FIX, candidate_head=head, original_review_scripts=ORIGINAL, executions=[], native_acceptance=False)
    def save(code, status):
        report.update(exit_code=code, status=status)
        (out / 'result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(dict(status=status, exit_code=code, candidate_head=head)))
        return code
    try:
        labels = [('baseline', BASELINE, []), ('pre-fix', PRE_FIX, FAILURE)]
        if not args.observe_only:
            labels.append(('candidate', head, []))
        builds = [(label, expected, prepare(repo, out, label, ref)) for label, ref, expected in labels]
        if args.prepare_only:
            return save(0, 'PREPARED_NOT_NATIVE_EXECUTED')
        if platform.system() != 'Darwin' or not shutil.which('xcrun'):
            return save(2, 'BLOCKED_MACOS_XCRUN_REQUIRED_NOT_RED')
        for label, expected, (files, binary) in builds:
            build = power.checked(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5', '-D', 'SWITCH_DIAGNOSTICS_TESTING', '-D', 'IOS_ATTEMPT_TESTING', *files, '-o', str(binary)])
            report['executions'].append(dict(source=label, **build))
            if build['exit_code']:
                return save(3, 'COMPILE_ERROR_NOT_RED')
            run = power.checked([str(binary), str(out / label / 'runtime'), 'error-envelope'], timeout=15)
            record = power.semantic_record(run, 'error-envelope')
            report['executions'].append(dict(source=label, native_record=record, **run))
            if run['exit_code'] != (1 if expected else 0) or record['failures'] != expected or record['status'] != ('semantic_failure' if expected else 'pass') or record['metrics']['wire_error_preserved'] is not True:
                return save(1, 'UNEXPECTED_SEMANTIC_RESULT')
        report['native_acceptance'] = not args.observe_only
        return save(0, 'EXACT_NATIVE_RED_OBSERVED' if args.observe_only else 'BASELINE_PASS_PREFIX_EXACT_RED_CANDIDATE_GREEN')
    except (ValueError, OSError, AssertionError, subprocess.SubprocessError) as error:
        report['error'] = str(error)
        return save(3, 'HARNESS_ERROR_NOT_RED')

if __name__ == '__main__':
    sys.exit(main())
