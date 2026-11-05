"""Required production provider RED/GREEN; macOS compile failures are not RED."""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess
import test_ipad_diagnostic_swift as ipad
ROOT = Path(__file__).resolve().parents[1]
BASE = '8f0875977c1ca6a8c35c2ba61159137bf0a507fb'
CASES = ['validation', 'manual', 'cold', 'legacy', 'stale', 'legacy-reasons', 'manager']
def main():
    p = argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    report = dict(baseline=BASE, native_acceptance=False, executions=[], candidate_head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip())
    def finish(code, status):
        report.update(exit_code=code, status=status)
        (a.output/'result.json').write_text(json.dumps(report, indent=2)); print(json.dumps(report)); return code
    ipad.BASE = BASE
    phases=[]
    for baseline in [True, False]:
        folder, files = ipad.prepare(a.output, baseline)
        main = folder/'main.swift'
        main.write_bytes((ROOT/'scripts/fixtures/ios_startup_transport_main.swift').read_bytes())
        (folder/'fixture.json').write_text(json.dumps({'sha256':hashlib.sha256(main.read_bytes()).hexdigest()}))
        phases.append((baseline, folder, files))
    if platform.system() != 'Darwin' or not shutil.which('xcrun'): return finish(2, 'BLOCKED_MACOS_NOT_RED')
    for baseline, folder, files in phases:
        binary=folder/'transport'
        cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','IOS_ATTEMPT_TESTING','-D','SWITCH_DIAGNOSTICS_TESTING','-D','PROVIDER_FIXTURE',*files,'-o',str(binary)]
        if not baseline: cmd[6:6] = ['-D', 'TRANSPORT_CANDIDATE']
        run=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
        report['executions'].append(dict(command=cmd,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
        if run.returncode: return finish(3,'COMPILE_ERROR_NOT_RED')
        for case in ['manual','cold'] if baseline else CASES:
            cmd=[str(binary),case]; run=subprocess.run(cmd,capture_output=True,text=True,timeout=25)
            report['executions'].append(dict(command=cmd,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
            if baseline:
                if run.returncode != 1 or f'FAIL TRANSPORT {case}: official channel failed before settings' not in run.stdout.splitlines(): return finish(1,'EXPECTED_SEMANTIC_RED_NOT_OBSERVED')
            elif run.returncode or f'PASS TRANSPORT {case}' not in run.stdout.splitlines(): return finish(1,'CANDIDATE_FAILURE')
    report['native_acceptance']=True
    return finish(0,'IMMUTABLE_PROVIDER_RED_CANDIDATE_GREEN_NOT_DEVICE_XPC')
if __name__ == '__main__': raise SystemExit(main())
