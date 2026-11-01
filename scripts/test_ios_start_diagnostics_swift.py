"""Mac-only production startup/logger behavior gate; Windows exit 2, never PASS.
No production method bodies are replaced. Immutable coordinator RED uses the
candidate logger to keep the boundary ABI identical; payloads exercise candidate.
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
ROOT = Path(__file__).resolve().parents[1]
BASE = 'dfbbc357bb213432e0f5ed69fc410ecf7a55c068'
CASES = ['immediate-failure','normal-connect','user-stop','late-generation','late-stop','payloads']

def prepare(out, baseline=False):
    folder = out / ('baseline' if baseline else 'candidate')
    folder.mkdir(parents=True, exist_ok=True)
    fixture = (ROOT/'scripts/fixtures/ios_restart_main.swift').read_text().split('let caseName =',1)[0]
    fixture = fixture[:fixture.index('enum SwitchDiagnostics {')]
    fixture = fixture.replace('func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }',
      'var fetches = 0\n  var pendingDisconnect: [(Error?) -> Void] = []\n  func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) { fetches += 1; pendingDisconnect.append(completionHandler) }')
    (folder/'main.swift').write_text(fixture+(ROOT/'scripts/fixtures/ios_start_diagnostics_main.swift').read_text())
    files=[]; manifest=[]
    for rel in ['ios/Runner/Tunnel/TunnelCoordinator.swift','ios/Runner/Tunnel/TunnelTypes.swift','ios/Shared/SwitchDiagnostics.swift']:
        raw = subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:{rel}']) if baseline and rel.endswith('TunnelCoordinator.swift') else (ROOT/rel).read_bytes()
        text=raw.decode().replace('\r\n','\n').replace('import NetworkExtension\n','')
        dest=folder/Path(rel).name; dest.write_bytes(text.encode()); files.append(str(dest))
        manifest.append({'path':rel,'ref':BASE if baseline and rel.endswith('TunnelCoordinator.swift') else 'candidate','sha256':hashlib.sha256(raw).hexdigest()})
    files.append(str(folder/'main.swift'))
    (folder/'sources.json').write_text(json.dumps(manifest,indent=2))
    return folder,files

def prepare_payload_red(out):
    folder=out/'payload-baseline';folder.mkdir(parents=True,exist_ok=True)
    raw=subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:ios/Shared/SwitchDiagnostics.swift'])
    (folder/'SwitchDiagnostics.swift').write_bytes(raw)
    fixture=(ROOT/'scripts/fixtures/ios_start_diagnostics_main.swift').read_text().split('Task { @MainActor in',1)[0]
    (folder/'main.swift').write_text('import Foundation\nimport Darwin\n'+fixture)
    return folder,[str(folder/'SwitchDiagnostics.swift'),str(folder/'main.swift')]

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--output',type=Path,required=True); parser.add_argument('--prepare-only',action='store_true'); args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    report={'native_acceptance':False,'executions':[],
            'candidate_head':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()}
    def finish(code,status):
        report.update(exit_code=code,status=status)
        (args.output/'result.json').write_text(json.dumps(report,indent=2)); print(json.dumps(report)); return code
    payload_folder,payload_files=prepare_payload_red(args.output)
    prepared=[('payload-red',payload_folder,payload_files),*[(baseline,*prepare(args.output,baseline)) for baseline in [True,False]]]
    if args.prepare_only: return finish(0,'PREPARED_NOT_EXECUTED')
    if platform.system()!='Darwin' or not shutil.which('xcrun'): return finish(2,'BLOCKED_MACOS_NOT_RED')
    for baseline,folder,files in prepared:
        binary=folder/'native'
        command=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','SWITCH_DIAGNOSTICS_TESTING']
        if baseline == 'payload-red': command+=['-D','PAYLOAD_BASELINE']
        command += [*files,'-o',str(binary)]
        build=subprocess.run(command,capture_output=True,text=True,timeout=120)
        report['executions'].append(dict(command=command,exit_code=build.returncode,stdout=build.stdout,stderr=build.stderr))
        if build.returncode: return finish(3,'COMPILE_ERROR_NOT_RED')
        modes = ['payloads'] if baseline == 'payload-red' else (['immediate-failure'] if baseline else CASES)
        for mode in modes:
            runtime=folder/mode;runtime.mkdir(exist_ok=True)
            command=[str(binary),mode,str(runtime)]
            run=subprocess.run(command,capture_output=True,text=True,timeout=20)
            report['executions'].append(dict(command=command,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
            if baseline == 'payload-red':
                if run.returncode!=1 or 'FAIL START-DIAGNOSTICS payloads: delay classification delay_positive' not in run.stdout: return finish(1,'EXPECTED_PAYLOAD_RED_NOT_OBSERVED')
            elif baseline:
                if run.returncode!=1 or 'FAIL START-DIAGNOSTICS immediate-failure: 2-5-1 must fetch exactly once' not in run.stdout: return finish(1,'EXPECTED_COORDINATOR_RED_NOT_OBSERVED')
            elif run.returncode or f'PASS START-DIAGNOSTICS {mode}' not in run.stdout: return finish(1,'CANDIDATE_SEMANTIC_FAILURE')
    report['native_acceptance']=True
    return finish(0,'COORDINATOR_RED_CANDIDATE_GREEN')
if __name__=='__main__': raise SystemExit(main())
