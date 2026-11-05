"""Guard immutable output baseline discovery in a real shallow checkout."""
from pathlib import Path
import argparse,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='e3990c473deae7e10386f3b2b3cd82e9192e089e'
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
 workflow=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text();job=workflow.split('\n  ios:\n',1)[1].split('\n  android:',1)[0]
 assert 'fetch-depth: 0'in job and 'python3 scripts/test_setup_process_output.py --output'in job
 shallow=a.output/'shallow';commands=[]
 def run(args,ok=True):
  q=subprocess.run(args,capture_output=True,text=True,timeout=90);commands.append({'command':args,'exit_code':q.returncode,'stderr':q.stderr})
  if ok:assert q.returncode==0,q.stderr
  return q
 if not shallow.exists():
  origin='file://'+ROOT.as_posix() if __import__('os').name=='nt' else ROOT.as_uri()
  run(['git','clone','--depth=1','--no-checkout','--no-local',origin,str(shallow)])
 before=run(['git','-C',str(shallow),'show',BASE+':setup.dart'],False);assert before.returncode!=0,'negative shallow control unexpectedly found baseline'
 run(['git','-C',str(shallow),'fetch','--unshallow','origin'])
 after=run(['git','-C',str(shallow),'show',BASE+':setup.dart']);assert 'systemEncoding.decode(data)'in after.stdout
 report={'status':'SHALLOW_BASELINE_MISSING_RED_FULL_HISTORY_GREEN','commands':commands,'immutable_baseline':BASE};(a.output/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps({'status':report['status'],'negative_exit':before.returncode,'restored_exit':after.returncode}))
if __name__=='__main__':main()
