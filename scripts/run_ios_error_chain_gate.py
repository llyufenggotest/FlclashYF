#!/usr/bin/env python3
"""Compile complete production routes; only framework/native dependencies doubled."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import test_ios_attempt_fixes_swift as attempt
import run_ios_power_gate as power
ROOT=Path(__file__).resolve().parents[1]

def prepare(repo,out,group):
    directory=out/group
    directory.mkdir(parents=True,exist_ok=True)
    manifest=[]
    files=[]
    paths=attempt.GROUPS[group]+attempt.COMMON+['ios/Shared/SwitchDiagnostics.swift']
    for rel in paths:
        raw=(repo/rel).read_bytes()
        text=attempt.transform(raw.decode(),rel)
        changes=['existing framework/bundle/container boundary transform']
        if rel.endswith('SwitchDiagnostics.swift'):
            anchor='    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {'
            assert text.count(anchor)==1
            text=text.replace(anchor,'    PowerProbe.bump("response_decode")\n'+anchor)
            changes.append('count exact response ingress decoder execution')
        dest=directory/Path(rel).name
        dest.write_bytes(text.encode()); files.append(str(dest))
        manifest.append(dict(path=rel,source_sha256=power.sha(raw),compiled_sha256=power.sha(dest.read_bytes()),changes=changes))
    rel='scripts/fixtures/ios_attempt_fixes_dependencies.swift'
    raw=(repo/rel).read_bytes(); text=raw.decode()
    begin=text.index('enum SwitchDiagnostics {'); end=text.index('enum IOSCoreBridge {',begin)
    text=text[:begin]+text[end:]
    text=text.replace('enum IOSCoreBridge {','enum IOSCoreBridge {\n  static var testReply = ""\n  static var testCalls = 0')
    anchor='    if holdApp { heldApp = completion } else { completion("{\\"result\\":\\"\\",\\"error\\":null}") }'
    assert text.count(anchor)==1
    text=text.replace(anchor,'    testCalls += 1\n    if holdApp { heldApp = completion } else { completion(testReply) }')
    text=text.replace('enum NECoreBridge {','enum NECoreBridge {\n  static var testReply: Data?')
    anchor='func invokeMethod(_ data: Data, completion: @escaping (Data?) -> Void) { completion(nil) }'
    assert text.count(anchor)==1
    text=text.replace(anchor,'func invokeMethod(_ data: Data, completion: @escaping (Data?) -> Void) { completion(testReply) }')
    dest=directory/'dependencies.swift';dest.write_bytes(text.encode());files.append(str(dest))
    manifest.append(dict(path=rel,source_sha256=power.sha(raw),compiled_sha256=power.sha(dest.read_bytes()),changes=['remove fake diagnostics; native Go reply/call-count boundary']))
    raw=(repo/'scripts/fixtures/ios_error_chain_main.swift').read_bytes()
    dest=directory/'main.swift';dest.write_bytes(raw);files.append(str(dest))
    manifest.append(dict(path='scripts/fixtures/ios_error_chain_main.swift',source_sha256=power.sha(raw),compiled_sha256=power.sha(raw),changes=[]))
    (directory/'sources.json').write_text(json.dumps(dict(candidate_head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),sources=manifest),indent=2))
    return directory,files

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--prepare-only',action='store_true')
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    report={'candidate_head':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),'executions':[],'native_acceptance':False}
    def save(code,status):
        report.update(exit_code=code,status=status)
        (out/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps({'exit_code':code,'status':status}));return code
    try:
        for group,cases in [('provider',['raw-error']),('integration',['mailbox-error','app-error','classifier-boundaries'])]:
            directory,files=prepare(ROOT,out,group)
            if a.prepare_only:continue
            if platform.system()!='Darwin' or not shutil.which('xcrun'):return save(2,'BLOCKED_MACOS_NOT_RED')
            command=['xcrun','--sdk','macosx','swiftc','-swift-version','5','-D','IOS_ATTEMPT_TESTING','-D','SWITCH_DIAGNOSTICS_TESTING']
            if group=='provider':command+=['-D','PROVIDER_FIXTURE']
            binary=directory/'native'
            build=power.checked([*command,*files,'-o',str(binary)])
            report['executions'].append(dict(group=group,**build))
            if build['exit_code']:return save(3,'COMPILE_ERROR_NOT_RED')
            for mode in cases:
                run=power.checked([str(binary),mode],timeout=25)
                records=[json.loads(line) for line in run['stdout'].splitlines() if line.startswith('{')]
                if len(records)!=1 or records[0].get('fixture')!='ios-error-production-chain-v1' or records[0].get('mode')!=mode:
                    raise ValueError('missing/duplicate chain record; not RED')
                record=records[0]
                report['executions'].append(dict(group=group,native_record=record,**run))
                if run['exit_code'] or record['failures'] or record['status']!='pass':return save(1,'SEMANTIC_FAILURE')
        report['native_acceptance']=not a.prepare_only
        return save(0,'PREPARED_NOT_NATIVE_EXECUTED' if a.prepare_only else 'NATIVE_PRODUCTION_CHAIN_GREEN')
    except (AssertionError,ValueError,OSError,subprocess.SubprocessError) as error:
        report['error']=str(error);return save(3,'HARNESS_ERROR_NOT_RED')
if __name__=='__main__':sys.exit(main())
