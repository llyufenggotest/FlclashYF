"""Run a deterministic partition of every tracked Flutter test, fail closed."""
from pathlib import Path
import argparse,json,os,subprocess,sys,time

def main():
 p=argparse.ArgumentParser();p.add_argument('--index',type=int,required=True);p.add_argument('--count',type=int,default=4);p.add_argument('--output',required=True);p.add_argument('--manifest-only',action='store_true');a=p.parse_args();assert 0<=a.index<a.count
 root=Path(__file__).resolve().parents[1];out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
 files=sorted(f for f in subprocess.check_output(['git','ls-files','test'],cwd=root,text=True).splitlines()if f.endswith('_test.dart'));parts=[files[i::a.count]for i in range(a.count)];assert sorted(f for part in parts for f in part)==files and len(set(files))==len(files);tests=parts[a.index];assert tests
 result={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'shard_index':a.index,'shard_count':a.count,'total_files':len(files),'files':tests,'all_partitions':parts,'manifest_only':a.manifest_only,'accepted':False};dest=out/'result.json';dest.write_text(json.dumps(result,indent=2))
 if a.manifest_only:return
 command=['flutter.bat'if os.name=='nt'else'flutter','test','--no-pub','--reporter','json',*tests];result['command']=command;started=time.monotonic()
 with(out/'flutter.jsonl').open('w',encoding='utf-8')as log:
  proc=subprocess.Popen(command,cwd=root,stdout=log,stderr=subprocess.STDOUT)
  try:code=proc.wait(timeout=900)
  except subprocess.TimeoutExpired:
   if os.name=='nt':subprocess.run(['taskkill.exe','/PID',str(proc.pid),'/T','/F'],capture_output=True,timeout=30)
   else:proc.kill()
   proc.wait();code=124
 done=[];errors=[];counts={}
 for line in(out/'flutter.jsonl').read_text(encoding='utf-8',errors='replace').splitlines():
  try:d=json.loads(line)
  except ValueError:continue
  if d.get('type')=='done':done.append(d)
  if d.get('type')=='error':errors.append(d)
  if d.get('type')=='testDone':
   key='skipped'if d.get('skipped')else d.get('result','unknown');counts[key]=counts.get(key,0)+1
 result.update(exit_code=code,elapsed=time.monotonic()-started,done=done,counts=counts,errors=errors,accepted=code==0 and bool(done)and done[-1].get('success')is True and not errors);dest.write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items()if k not in ['all_partitions','files','errors']}));sys.exit(0 if result['accepted']else 1)
if __name__=='__main__':main()
