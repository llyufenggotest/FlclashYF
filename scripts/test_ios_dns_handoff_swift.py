"""Fail-closed macOS gate: immutable real Swift RED then candidate GREEN.
Windows preparation is not native acceptance. Only framework boundaries doubled.
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import test_ios_attempt_fixes_swift as integration
ROOT = Path(__file__).resolve().parents[1]
BASE = 'a3aa75b3b7c851caa80d9d6964158d7e5ffbb478'
PATHS = integration.GROUPS['integration'] + integration.COMMON
R1_BASE = '3331244162c7cd0c234b5cb9be5215cef37cd775'
R1_CASES = ['reload-during-idle-suspend', 'reload-during-idle-resume']
CASES = ['suspend-barrier', 'toggle-start', 'superseded-start', 'terminal-stop', 'suspend-false',
         'active-config', 'connecting-config', 'stop-restore', 'stop-failure', 'stale-status',
         'late-resume', 'offline-config', 'resume-false', 'envelopes'] + R1_CASES
BASELINE_REDS = {
    BASE: {'suspend-barrier': 'FAIL DNS suspend-barrier: start crossed unreleased App DNS listener'},
    R1_BASE: {case: f'FAIL DNS {case}: configuration waiters stranded by idle DNS await' for case in R1_CASES},
}

def prepare(out, baseline, baseline_ref=BASE):
    folder = out / (('baseline-r1' if baseline_ref == R1_BASE else 'baseline') if baseline else 'candidate')
    folder.mkdir(parents=True, exist_ok=True)
    files = []
    manifest = []
    for rel in PATHS:
        raw = subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{baseline_ref}:{rel}']) if baseline else (ROOT/rel).read_bytes()
        dest = folder/Path(rel).name
        dest.write_text(integration.transform(raw.decode(), rel), encoding='utf-8')
        files.append(str(dest))
        manifest.append(dict(path=rel, sha256=hashlib.sha256(raw).hexdigest(), ref=baseline_ref if baseline else 'candidate'))
    deps = (ROOT/'scripts/fixtures/ios_attempt_fixes_dependencies.swift').read_text()
    deps = deps[:deps.index('enum IOSCoreBridge {')] + (ROOT/'scripts/fixtures/ios_dns_handoff_bridge.swift').read_text()
    # Record actual system start/stop calls, not a replacement state machine.
    deps = deps.replace('func startVPNTunnel() throws { status = .connecting }', 'var starts = 0, stops = 0\n  var holdStop = false\n  func startVPNTunnel() throws { starts += 1; status = .connecting }')
    deps = deps.replace('func stopVPNTunnel() { status = .disconnected }', 'func stopVPNTunnel() { stops += 1; status = holdStop ? .disconnecting : .disconnected }')
    deps = deps.replace('func saveToPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }',
        'var preferenceSaves = 0\n  func saveToPreferences(completionHandler: @escaping (Error?) -> Void) { preferenceSaves += 1; completionHandler(nil) }')
    depfile=folder/'dependencies.swift'; depfile.write_text(deps,encoding='utf-8'); files.append(str(depfile))
    mainfile=folder/'main.swift'; mainfile.write_bytes((ROOT/'scripts/fixtures/ios_dns_handoff_main.swift').read_bytes()); files.append(str(mainfile))
    manifest.append(dict(fixture_sha256=hashlib.sha256(mainfile.read_bytes()).hexdigest()))
    (folder/'sources.json').write_text(json.dumps(manifest,indent=2))
    return folder,files

def main():
    p=argparse.ArgumentParser(); p.add_argument('--output',type=Path,required=True); p.add_argument('--prepare-only',action='store_true'); a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    report=dict(native_acceptance=False, executions=[],
                candidate_head=subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip())
    def finish(code,status):
        report.update(exit_code=code,status=status)
        (a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));return code
    phases=[(ref,*prepare(a.output,True,ref)) for ref in [BASE,R1_BASE]]
    phases.append((None,*prepare(a.output,False)))
    if a.prepare_only:return finish(0,'PREPARED_NOT_EXECUTED')
    if platform.system()!='Darwin' or not shutil.which('xcrun'):return finish(2,'BLOCKED_MACOS_NOT_RED')
    for baseline,folder,files in phases:
        binary=folder/'native'
        cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','IOS_ATTEMPT_TESTING',*files,'-o',str(binary)]
        built=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
        report['executions'].append(dict(command=cmd,exit_code=built.returncode,stdout=built.stdout,stderr=built.stderr))
        if built.returncode:return finish(3,'COMPILE_ERROR_NOT_RED')
        for case in BASELINE_REDS[baseline] if baseline else CASES:
            cmd=[str(binary),case];run=subprocess.run(cmd,capture_output=True,text=True,timeout=25)
            report['executions'].append(dict(command=cmd,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
            if baseline:
                if run.returncode!=1 or BASELINE_REDS[baseline][case] not in run.stdout.splitlines():return finish(1,'EXPECTED_SEMANTIC_RED_NOT_OBSERVED')
            elif run.returncode or f'PASS DNS {case}' not in run.stdout:return finish(1,'CANDIDATE_SEMANTIC_FAILURE')
    report['native_acceptance']=True
    return finish(0,'IMMUTABLE_RED_CANDIDATE_GREEN')
if __name__=='__main__':raise SystemExit(main())
