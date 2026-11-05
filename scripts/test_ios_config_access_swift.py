"""Required Mac production slice RED/GREEN and full provider failure/export gate.
Exit 2 is blocked, compile/harness errors 3 are never semantic RED.
"""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess
import test_ipad_diagnostic_swift as ipad
import test_ios_attempt_fixes_swift as attempt
ROOT=Path(__file__).resolve().parents[1]
BASE='81e70f1c0c646cc93b2e5f21bcbb4e3926e44817'
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 report=dict(base=BASE,head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),native_acceptance=False,executions=[])
 def finish(code,status):
  # Keep the exact quoted-path runtime regression, but nest its filesystem
  # evidence in a portable ZIP: upload-artifact rejects quotes in member paths.
  runtime_archives=[]
  for label in ['baseline-slice','candidate-slice']:
   folder=a.output/label;runtime=folder/'quoted"home'
   if runtime.exists():
    import zipfile
    archive=folder/'quoted-home-runtime.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
     for entry in runtime.rglob('*'):
      if entry.is_file():z.write(entry,entry.relative_to(folder).as_posix())
    with zipfile.ZipFile(archive) as z:assert z.testzip() is None
    runtime_archives.append(dict(path=str(archive),sha256=hashlib.sha256(archive.read_bytes()).hexdigest()))
    shutil.rmtree(runtime)
  report.update(exit_code=code,status=status,runtime_archives=runtime_archives);(a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(dict(exit_code=code,status=status)));return code
 def run(cmd,timeout=120):
  r=subprocess.run(cmd,capture_output=True,text=True,timeout=timeout);report['executions'].append(dict(command=cmd,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr));return r
 prepared=[]
 for baseline in [True,False]:
  folder=a.output/('baseline-slice' if baseline else 'candidate-slice');folder.mkdir(exist_ok=True)
  files=[];manifest=[]
  for rel in ['ios/Shared/StartupEnvelope.swift','ios/NECore/PacketTunnelSharedStateStore.swift','ios/NECore/RPCSession.swift']:
   raw=subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:{rel}']) if baseline else (ROOT/rel).read_bytes()
   dest=folder/Path(rel).name;dest.write_text(attempt.transform(raw.decode(),rel));files.append(str(dest));manifest.append(dict(path=rel,ref=BASE if baseline else 'candidate',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),compiled_sha256=hashlib.sha256(dest.read_bytes()).hexdigest()))
  dep='''import Foundation
var fixtureContainer: URL?
extension FileManager { func testContainerURL(forSecurityApplicationGroupIdentifier: String) -> URL? { fixtureContainer } }
'''
  (folder/'dependencies.swift').write_text(dep);files.append(str(folder/'dependencies.swift'))
  (folder/'main.swift').write_bytes((ROOT/'scripts/fixtures/config_access_main.swift').read_bytes());files.append(str(folder/'main.swift'))
  (folder/'sources.json').write_text(json.dumps(manifest,indent=2));prepared.append((baseline,folder,files))
 if platform.system()!='Darwin' or not shutil.which('xcrun'):return finish(2,'BLOCKED_MACOS_NOT_RED')
 for baseline,folder,files in prepared:
  binary=folder/'slice';cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','5']
  if not baseline:cmd+=['-D','CONFIG_ACCESS_CANDIDATE']
  r=run([*cmd,*files,'-o',str(binary)])
  if r.returncode:return finish(3,'COMPILE_ERROR_NOT_RED')
  runtime=folder/'quoted"home';r=run([str(binary),str(runtime),'baseline' if baseline else 'candidate'])
  if baseline:
   if r.returncode!=1 or 'FAIL CONFIG ACCESS: actual Core home JSON invalid' not in r.stdout:return finish(1,'EXPECTED_SEMANTIC_RED_NOT_OBSERVED')
  elif r.returncode or 'PASS CONFIG ACCESS candidate' not in r.stdout:return finish(1,'CANDIDATE_SLICE_FAILURE')
 # Full unchanged provider/manager/coordinator/diagnostic method bodies with only
 # framework boundaries doubled; callback failure must survive local export.
 folder,files=ipad.prepare(a.output/'full',False)
 (folder/'main.swift').write_bytes((ROOT/'scripts/fixtures/config_access_provider.swift').read_bytes())
 binary=folder/'native';cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','IOS_ATTEMPT_TESTING','-D','SWITCH_DIAGNOSTICS_TESTING','-D','PROVIDER_FIXTURE',*files,'-o',str(binary)]
 if run(cmd,180).returncode:return finish(3,'FULL_COMPILE_ERROR_NOT_RED')
 for case in ['failure-export','owner-cold']:
  runtime=folder/case;runtime.mkdir(exist_ok=True)
  r=run([str(binary),case,str(runtime)],30)
  if r.returncode or f'PASS CONFIG ACCESS {case}' not in r.stdout:return finish(1,'FULL_SEMANTIC_FAILURE')
 report['native_acceptance']=True
 return finish(0,'IMMUTABLE_SLICE_RED_PRODUCTION_GREEN_NOT_DEVICE_SANDBOX')
if __name__=='__main__':raise SystemExit(main())
