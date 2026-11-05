"""Required R1/R2 production-source Mac gate, immutable review HEAD RED.
Original review fixture is preserved byte-for-byte; candidate setup uses the
new revision receipt, while every original assertion/oracle remains unchanged.
"""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess
import test_ipad_diagnostic_swift as gate
ROOT = Path(__file__).resolve().parents[1]
BASE = '6a95950d54b4e1fefe3507b0730ebeab95d9095c'
ORIGINAL_SHA = '8b5a912e9f8b8e073db61ca0255e4aba544cb66fd7cba2ca13c0e2fb8130093c'
REDS = {'routes':'valid 257-entry list rejected before start/sync',
        'bypass':'valid 257-entry list rejected before start/sync',
        'active':'connected configuration edit made active options nil; direct VpnManager caller suppresses restart warning'}
def main():
    p = argparse.ArgumentParser(); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    original=(ROOT/'scripts/fixtures/startup_review_original.swift').read_bytes()
    assert hashlib.sha256(original).hexdigest() == ORIGINAL_SHA
    report=dict(baseline=BASE,native_acceptance=False,executions=[],original_sha256=ORIGINAL_SHA,
        candidate_head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
        limits=['framework doubles, not Apple XPC/save-reload or device traffic',
                'candidate original fixture changes only make/saveRunTime setup to pass authoritative revision; oracle bytes unchanged'])
    def finish(code,status):
        report.update(exit_code=code,status=status)
        (a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));return code
    prepared=[]
    gate.BASE=BASE
    for baseline in [True,False]:
        folder,files=gate.prepare(a.output,baseline)
        # Unlike the older pre-helper baseline, 6a959 includes the helper: bind
        # ALL baseline production files (including StartupEnvelope) to that SHA.
        if baseline:
            raw=subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:ios/Shared/StartupEnvelope.swift'])
            dest=folder/'StartupEnvelope.swift';dest.write_text(gate.attempt.transform(raw.decode(),'ios/Shared/StartupEnvelope.swift'))
            manifest=json.loads((folder/'sources.json').read_text())
            for entry in manifest:
                if entry['path']=='ios/Shared/StartupEnvelope.swift':
                    entry.update(ref=BASE,sha256=hashlib.sha256(raw).hexdigest(),compiled_sha256=hashlib.sha256(dest.read_bytes()).hexdigest())
            (folder/'sources.json').write_text(json.dumps(manifest,indent=2))
        text=original.decode()
        if not baseline:
            text=text.replace('let running = try StartupEnvelope.make(shared:original)', 'let running = try store.loadStartupEnvelope()')
            text=text.replace('saveRunTime(vpnOptions: running.options)', 'saveRunTime(vpnOptions: running.options, revision: running.revision)')
        (folder/'main.swift').write_text(text)
        prepared.append((baseline,folder,files))
    if platform.system()!='Darwin' or not shutil.which('xcrun'):return finish(2,'BLOCKED_MACOS_NOT_NATIVE_EXECUTED')
    for baseline,folder,files in prepared:
        fixtures=[('original',list(REDS))] if baseline else [('original',list(REDS)),('extra',['metadata','budget','provider-receipt'])]
        for fixture,cases in fixtures:
            if fixture=='extra':(folder/'main.swift').write_bytes((ROOT/'scripts/fixtures/startup_review_extra.swift').read_bytes())
            binary=folder/fixture
            report.setdefault('fixtures', []).append(dict(baseline=baseline, fixture=fixture,
                sha256=hashlib.sha256((folder/'main.swift').read_bytes()).hexdigest()))
            (folder/(fixture+'-main.swift.txt')).write_bytes((folder/'main.swift').read_bytes())
            cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','IOS_ATTEMPT_TESTING','-D','SWITCH_DIAGNOSTICS_TESTING','-D','PROVIDER_FIXTURE',*files,'-o',str(binary)]
            run=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
            report['executions'].append(dict(baseline=baseline,command=cmd,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
            if run.returncode:return finish(3,'COMPILE_ERROR_NOT_RED')
            for case in cases:
                cmd=[str(binary),case];run=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
                report['executions'].append(dict(baseline=baseline,command=cmd,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
                if baseline:
                    if run.returncode!=1 or f'FAIL REVIEW {case}: {REDS[case]}' not in run.stdout.splitlines():return finish(1,'EXPECTED_REVIEW_SEMANTIC_RED_NOT_OBSERVED')
                elif run.returncode or f'PASS {"REVIEW" if fixture=="original" else "EXTRA"} {case}' not in run.stdout.splitlines():return finish(1,'CANDIDATE_FAILURE')
    report['native_acceptance']=True
    return finish(0,'REVIEW_HEAD_RED_CANDIDATE_GREEN_NOT_DEVICE_XPC')
if __name__=='__main__':raise SystemExit(main())
