"""Execute the production function body with real Go GC on host.

Only log/tunnel/platform boundaries are stubs; GC and scavenging are real.
"""
import argparse
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
source = Path(__file__).with_name('hub.go').read_text(encoding='utf-8')
body = source[source.index('func handleForceGC() {'):source.index('func handleShutdown() bool {')]
program = '''package main
import("runtime";"runtime/debug";"encoding/json";"os";"time")
type logger struct{ Calls int };func(l *logger)Infoln(_ string){l.Calls++}
type tunnelStub struct{ Calls int };func(t *tunnelStub)InvalidateAllProxies(){t.Calls++}
var log=&logger{};var tunnel=&tunnelStub{}
var features=struct{Android,IOS bool}{os.Args[1]=="android",os.Args[1]=="ios"}
''' + body + '''
func main(){
 debug.SetGCPercent(-1)
 debug.SetMemoryLimit(1<<60)
 var before,after runtime.MemStats
 runtime.GC();runtime.ReadMemStats(&before)
 start:=time.Now()
 for i:=0;i<5;i++{handleForceGC()}
 runtime.ReadMemStats(&after)
 json.NewEncoder(os.Stdout).Encode(map[string]any{"platform":os.Args[1],"calls":5,"num_gc":after.NumGC-before.NumGC,"elapsed_ns":time.Since(start).Nanoseconds(),"pause_ns":after.PauseTotalNs-before.PauseTotalNs,"invalidations":tunnel.Calls,"diagnostic_logs":log.Calls})
}
'''
path = a.output / 'force_gc_production.go'
path.write_text(program, encoding='utf-8')
results = []
for platform in ('ios', 'android', 'desktop'):
    command = ['go', 'run', str(path.resolve()), platform]
    proc = subprocess.run(command, capture_output=True, text=True, timeout=120)
    record = dict(command=command, exit=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
    if proc.returncode == 0:
        record['metrics'] = json.loads(proc.stdout)
        m = record['metrics']
        record['pass'] = m['num_gc'] == 5 and m['invalidations'] == 5 and m['diagnostic_logs'] == 5
    else:
        record['pass'] = False
    results.append(record)
    print(json.dumps(record))
(a.output / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
assert all(r['pass'] for r in results), 'five forceGC calls must run five GC cycles, with invalidation and diagnostics intact'
