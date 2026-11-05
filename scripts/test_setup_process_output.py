"""Exercise exact build-log forwarding with real split-byte subprocesses."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='e3990c473deae7e10386f3b2b3cd82e9192e089e'
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
 dart=shutil.which('dart.bat')or shutil.which('dart');assert dart
 fixture=(ROOT/'scripts/fixtures/setup_process_output.dart').read_bytes();(a.output/'child.dart').write_bytes(fixture)
 report={'candidate_head':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),'baseline':BASE,'baseline_boundary':'Exact old forwarding body; Windows host explicitly emulates CI UTF-8 systemEncoding, since Windows systemEncoding is non-UTF8','executions':[]}
 setup=(ROOT/'setup.dart').read_text();assert "import 'tool/process_output.dart';"in setup and 'final buildExit = await forwardBuildOutput(process);'in setup
 for baseline in [True,False]:
  folder=a.output/('baseline'if baseline else'candidate');folder.mkdir(exist_ok=True)
  if baseline:
   source=subprocess.check_output(['git','-C',str(ROOT),'show',BASE+':setup.dart']).decode();start=source.index('  process.stdout.listen',source.index('Future<int> packageIOSNoSign'));end=source.index('  if (buildExit',start);body=source[start:end]+'  return buildExit;\n';body=body.replace('systemEncoding.decode(data)', 'utf8.decode(data)') if __import__('platform').system()=='Windows' else body;helper="import 'dart:convert';\nimport 'dart:io';\nFuture<int> forwardBuildOutput(Process process) async {\n"+body+'}\n'
  else:helper=(ROOT/'tool/process_output.dart').read_text()
  (folder/'process_output.dart').write_text(helper)
  (folder/'main.dart').write_text("import 'dart:io';\nimport 'process_output.dart';\nFuture<void> main(List<String> args) async { final p = await Process.start(Platform.resolvedExecutable, args); exitCode = await forwardBuildOutput(p); }\n")
  for code in [0,7]:
   cmd=[dart,str(folder/'main.dart'),str(a.output/'child.dart'),str(code)];q=subprocess.run(cmd,capture_output=True,timeout=40);expected=b'A'*65535+'中😀\n'.encode();err='错误✓\n'.encode();row={'baseline':baseline,'child_exit':code,'exit_code':q.returncode,'stdout_sha256':hashlib.sha256(q.stdout).hexdigest(),'stdout_exact':q.stdout==expected,'stderr_exact':q.stderr==err};report['executions'].append(row);(folder/('stderr-'+str(code)+'.log')).write_bytes(q.stderr)
   if baseline:assert q.returncode!=code and b'FormatException'in q.stderr,'immutable UTF8 failure not reproduced'
   else:assert q.returncode==code and row['stdout_exact']and row['stderr_exact'],row
 report['status']='IMMUTABLE_SPLIT_UTF8_RED_RAW_BYTES_GREEN';(a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
if __name__=='__main__':main()
