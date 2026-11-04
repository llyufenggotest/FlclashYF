"""Run exact production Dart export without unrelated Rust native hooks."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='de6517d43c3a3277df4f0ce14c42b3f791f9fb05'
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    flutter=shutil.which('flutter.bat') or shutil.which('flutter')
    report={'baseline':BASE,'candidate_head':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),'executions':[],'source_hashes':{},'status':'not_executed'}
    def finish(code,status):
        report.update(exit_code=code,status=status);(a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));return code
    if not flutter:return finish(2,'FLUTTER_UNAVAILABLE')
    for baseline in [True,False]:
        folder=(a.output/('baseline' if baseline else 'candidate')).resolve();(folder/'lib/common').mkdir(parents=True,exist_ok=True);(folder/'test').mkdir(exist_ok=True)
        (folder/'pubspec.yaml').write_text('name: fl_clash\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n')
        raw=subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:lib/common/native_log_export.dart']) if baseline else (ROOT/'lib/common/native_log_export.dart').read_bytes()
        (folder/'lib/common/native_log_export.dart').write_bytes(raw)
        report['source_hashes']['baseline' if baseline else 'candidate']=hashlib.sha256(raw).hexdigest()
        test=(ROOT/'scripts/fixtures/ipad_diagnostic_export_test.dart').read_text()
        if baseline:
            begin=test.index('      runnerDiagnosticReader:');end=test.index('\n      );',begin)
            test=test[:begin]+test[end:]
            test=test.replace('      expect(calls, 1);\n','')
        (folder/'test/ipad_export_test.dart').write_text(test)
        (folder/'test/native_log_export_test.dart').write_bytes((ROOT/'test/common/native_log_export_test.dart').read_bytes())
        for args in [['pub','get'],['test','--no-pub','--no-test-assets','test/ipad_export_test.dart',*([] if baseline else ['test/native_log_export_test.dart'])]]:
            cmd=[flutter,*args];run=subprocess.run(cmd,cwd=folder,capture_output=True,text=True,timeout=180)
            report['executions'].append(dict(baseline=baseline,command=cmd,exit_code=run.returncode,stdout=run.stdout,stderr=run.stderr))
            (folder/('pub.log' if args[0]=='pub' else 'test.log')).write_text(run.stdout+run.stderr)
            if args[0]=='pub' and run.returncode:return finish(3,'PUB_ERROR_NOT_RED')
            if args[0]=='test':
                if baseline:
                    if run.returncode!=1 or 'provider_stage=rpc_publication' not in run.stdout or 'Failed to load' in run.stdout:return finish(1,'EXPECTED_EXPORT_RED_NOT_OBSERVED')
                elif run.returncode:return finish(1,'EXPORT_GREEN_FAILED')
    return finish(0,'DART_PRODUCTION_BASELINE_RED_CANDIDATE_GREEN')
if __name__=='__main__':raise SystemExit(main())
