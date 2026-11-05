"""Full Flutter native hooks require complete checkout and matching inputs."""
from pathlib import Path
import re,unittest
ROOT=Path(__file__).resolve().parents[1]

def valid(text):
 match=re.search(r'^  flutter-full:\n(.*?)(?=^  [\w-]+:|\Z)',text,re.M|re.S)
 if not match:return False
 job=match.group(1)
 required=['submodules: recursive','actions/setup-go@','go-version: ${{ env.GO_VERSION }}','OIX_DNS_AUTH_SEED: ${{ secrets.OIX_DNS_AUTH_SEED }}','python3 scripts/prepare_oix_dns_auth.py','run_full_flutter_shard.py','if: always()','if-no-files-found: error']
 return all(x in job for x in required)and job.index('prepare_oix_dns_auth.py')<job.index('flutter pub get')<job.index('run_full_flutter_shard.py')

class Wiring(unittest.TestCase):
 def test_production(self):self.assertTrue(valid((ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()))
 def test_negative_prerequisites(self):
  text=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text();start=text.index('  flutter-full:');end=text.index('\n  android:',start)
  for token in ['submodules: recursive','actions/setup-go@','OIX_DNS_AUTH_SEED: ${{ secrets.OIX_DNS_AUTH_SEED }}','python3 scripts/prepare_oix_dns_auth.py']:
   with self.subTest(token=token):self.assertFalse(valid(text[:start]+text[start:end].replace(token,'removed-required-input')+text[end:]))
 def test_all_package_jobs_depend_on_complete_suite(self):
  text=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
  for name in ['android','windows','ios','macos']:
   job=re.search(r'^  '+name+r':\n(.*?)(?=^  [\w-]+:|\Z)',text,re.M|re.S).group(1)
   needs=re.search(r'^    needs: \[([^\]]+)\]',job,re.M).group(1)
   self.assertIn('flutter-full',[x.strip()for x in needs.split(',')])
if __name__=='__main__':unittest.main()
