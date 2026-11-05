"""Mac-required immutable actual-handler semantic RED, candidate exact-source GREEN.
Exit 2 blocked, exit 3 compile/harness error: neither counts as RED or acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
from test_ios_official_ipc import body, BASE
ROOT = Path(__file__).resolve().parents[1]
CASES = ['handler','echo','status','nil','mismatch','wrong-nonce','wrong-receipt','oversize','error','profile','hold','load-timeout']
def prepare(out, baseline):
    folder = out / ('baseline' if baseline else 'candidate')
    folder.mkdir(parents=True, exist_ok=True)
    manifest = []
    def put(name, raw, source, changes):
        target = folder/name
        target.write_bytes(raw)
        manifest.append(dict(path=source,compiled_file=name,compiled_sha256=hashlib.sha256(raw).hexdigest(),changes=changes))
        return str(target)
    paths = []
    rel = 'ios/Shared/StartupEnvelope.swift'
    raw = (ROOT/rel).read_bytes()
    paths.append(put('StartupEnvelope.swift',raw,rel,[]))
    manifest[-1]['source_sha256'] = hashlib.sha256(raw).hexdigest()
    rel = 'ios/Runner/OfficialIPCProbe.swift'
    raw = (ROOT/rel).read_bytes()
    text = raw.decode().replace('import NetworkExtension\n','').replace('(Bundle.main.bundleIdentifier ?? "")','"fixture"').replace('UserDefaults.standard','fixtureDefaults')
    paths.append(put('OfficialIPCProbe.swift',text.encode(),rel,['framework/session boundary doubles','fixture bundle identity','isolated real UserDefaults suite']))
    manifest[-1]['source_sha256'] = hashlib.sha256(raw).hexdigest()
    rel = 'ios/NECore/PacketTunnelProvider.swift'
    raw = subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:{rel}']) if baseline else (ROOT/rel).read_bytes()
    source = raw.decode().replace('\r\n','\n')
    handler = body(source,'override func handleAppMessage(')
    dep = (ROOT/'scripts/fixtures/official_ipc_dependencies.swift').read_text().replace('// EXACT_HANDLER',handler)
    dep += '\nlet fixtureSuite = "official-ipc-fixture-" + UUID().uuidString\nlet fixtureDefaults = UserDefaults(suiteName: fixtureSuite)!\n'
    paths.append(put('dependencies.swift',dep.encode(),rel,['exact full production handleAppMessage method slice','only framework/Core boundary dependencies doubled']))
    manifest[-1].update(source_sha256=hashlib.sha256(raw).hexdigest(),slice_sha256=hashlib.sha256(handler.encode()).hexdigest(),ref=BASE if baseline else 'candidate')
    raw = (ROOT/'scripts/fixtures/official_ipc_main.swift').read_bytes()
    paths.append(put('main.swift',raw,'scripts/fixtures/official_ipc_main.swift',[]))
    (folder/'sources.json').write_text(json.dumps(manifest,indent=2))
    return folder, paths

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    report=dict(base=BASE,candidate_head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),native_acceptance=False,device_delivery_proven=False,executions=[],limitations=['Apple NetworkExtension session boundary doubled; real signed iPad public IPC required','not a VPN/configuration/resource-transfer fix'])
    def finish(code,status):
        report.update(exit_code=code,status=status)
        (a.output/'result.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(dict(exit_code=code,status=status)))
        return code
    try:
        prepared=[(b,*prepare(a.output,b)) for b in [True,False]]
        if platform.system()!='Darwin' or not shutil.which('xcrun'):return finish(2,'BLOCKED_MACOS_NOT_RED')
        for baseline,folder,files in prepared:
            binary=folder/'native'
            cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','5',*files,'-o',str(binary)]
            r=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
            report['executions'].append(dict(command=cmd,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr))
            if r.returncode:return finish(3,'COMPILE_ERROR_NOT_RED')
            for case in ['handler'] if baseline else CASES:
                cmd=[str(binary),case];r=subprocess.run(cmd,capture_output=True,text=True,timeout=25)
                report['executions'].append(dict(command=cmd,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr))
                if baseline:
                    if r.returncode!=1 or 'FAIL OFFICIAL IPC: actual handler did not echo reserved probe' not in r.stdout:return finish(1,'EXPECTED_SEMANTIC_RED_NOT_OBSERVED')
                elif r.returncode or f'PASS OFFICIAL IPC {case}' not in r.stdout:return finish(1,'CANDIDATE_SEMANTIC_FAILURE')
        report['native_acceptance']=True
        return finish(0,'IMMUTABLE_HANDLER_RED_PRODUCTION_GREEN_NOT_DEVICE_IPC')
    except (AssertionError,ValueError,OSError,subprocess.SubprocessError) as e:
        report['harness_error_type']=type(e).__name__
        return finish(3,'HARNESS_ERROR_NOT_RED')
if __name__=='__main__':raise SystemExit(main())
