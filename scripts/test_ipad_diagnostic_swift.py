"""One full production Swift binary: storage, provider, coordinator, export.
macOS exit 2 is blocked, compile errors exit 3 never semantic RED.
"""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess
import test_ios_attempt_fixes_swift as attempt
ROOT=Path(__file__).resolve().parents[1]
BASE='de6517d43c3a3277df4f0ce14c42b3f791f9fb05'
CASES=['sink-failure','underlying','provider-publication','provider-network-error','queue-caps','privacy','no-entry']
PATHS=['ios/NECore/PacketTunnelProvider.swift','ios/NECore/PacketTunnelLifecycleCleanup.swift','ios/NECore/RPCSession.swift','ios/NECore/PacketTunnelSharedStateStore.swift','ios/Runner/Storage/SharedStateStore.swift','ios/Runner/Tunnel/TunnelCoordinator.swift','ios/Runner/Tunnel/TunnelManagerStore.swift','ios/Runner/Tunnel/TunnelTypes.swift','ios/Shared/SwitchDiagnostics.swift']
def prepare(out,baseline=False):
    folder=out/('baseline' if baseline else 'candidate');folder.mkdir(parents=True,exist_ok=True)
    files=[];manifest=[]
    for rel in PATHS:
        raw=subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:{rel}']) if baseline else (ROOT/rel).read_bytes()
        text=attempt.transform(raw.decode(),rel)
        dest=folder/Path(rel).name;dest.write_text(text,encoding='utf-8');files.append(str(dest))
        manifest.append(dict(path=rel,sha256=hashlib.sha256(raw).hexdigest(),compiled_sha256=hashlib.sha256(dest.read_bytes()).hexdigest()))
    dep=(ROOT/'scripts/fixtures/ios_attempt_fixes_dependencies.swift').read_text()
    begin=dep.index('enum SwitchDiagnostics {');end=dep.index('enum IOSCoreBridge {',begin)
    dep=dep[:begin]+dep[end:]
    dep=dep.replace('func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }','var lastError: Error?; var fetches = 0\n  func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) { fetches += 1; completionHandler(lastError) }')
    dep+='\nenum CoreMessageRouter { static func setAppDNSListenerSuspended(_ suspended: Bool) async -> Bool { true } }\n'
    dest=folder/'dependencies.swift';dest.write_text(dep);files.append(str(dest))
    dest=folder/'main.swift';dest.write_bytes((ROOT/'scripts/fixtures/ipad_diagnostic_main.swift').read_bytes());files.append(str(dest))
    (folder/'sources.json').write_text(json.dumps(manifest,indent=2))
    return folder,files

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--prepare-only',action='store_true');a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    report=dict(schema='iPadDiagnostic-v1',base=BASE,candidate_head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),native_acceptance=False,executions=[],limits=['framework boundary doubles; Apple system cross-process delivery still device-required','Flutter engine/Dart validated separately, not replaced by native fixture'])
    def finish(code,status):
        report.update(exit_code=code,status=status);(a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));return code
    prepared=[(b,*prepare(a.output,b)) for b in [True,False]]
    if a.prepare_only:return finish(0,'PREPARED_NOT_NATIVE_EXECUTED')
    if platform.system()!='Darwin' or not shutil.which('xcrun'):return finish(2,'BLOCKED_MACOS_NOT_RED')
    for baseline,folder,files in prepared:
        command=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','IOS_ATTEMPT_TESTING','-D','SWITCH_DIAGNOSTICS_TESTING','-D','PROVIDER_FIXTURE']
        if baseline:command+=['-D','IPAD_BASELINE']
        binary=folder/'native';command += [*files,'-o',str(binary)]
        build=subprocess.run(command,capture_output=True,text=True,timeout=180);report['executions'].append(dict(command=command,exit_code=build.returncode,stdout=build.stdout,stderr=build.stderr))
        if build.returncode:return finish(3,'COMPILE_ERROR_NOT_RED')
        for mode in ['no-entry'] if baseline else CASES:
            runtime=folder/mode;runtime.mkdir(exist_ok=True)
            command=[str(binary),mode,str(runtime)];run=subprocess.run(command,capture_output=True,text=True,timeout=30);report['executions'].append(dict(command=command,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
            if baseline:
                if run.returncode!=1 or 'independent Runner evidence absent' not in run.stdout:return finish(1,'EXPECTED_SEMANTIC_RED_NOT_OBSERVED')
            elif run.returncode or f'PASS IPAD {mode}' not in run.stdout:return finish(1,'CANDIDATE_SEMANTIC_FAILURE')
    report['native_acceptance']=True
    return finish(0,'BASELINE_RED_CANDIDATE_GREEN')
if __name__=='__main__':raise SystemExit(main())
