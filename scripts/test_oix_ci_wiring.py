"""Ensure private Oix input exists in every isolated build job."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class WiringTests(unittest.TestCase):
    def test_every_job_prepares_private_input_before_build(self):
        text = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text()
        lines = text.splitlines()
        jobs = {}
        current = None
        for line in lines:
            if line.startswith('  ') and not line.startswith('   ') and line.endswith(':'):
                current = line.strip()[:-1]
                jobs[current] = []
            elif current:
                jobs[current].append(line)
        for name in ('verify', 'android', 'windows', 'ios', 'macos'):
            with self.subTest(job=name):
                body = '\n'.join(jobs[name])
                self.assertEqual(body.count('Prepare private Oix DNS-Auth build input'), 1)
                self.assertIn('OIX_DNS_AUTH_SEED: ${{ secrets.OIX_DNS_AUTH_SEED }}', body)
                self.assertIn('scripts/prepare_oix_dns_auth.py', body)
                if name != 'verify':
                    self.assertLess(body.index('scripts/prepare_oix_dns_auth.py'), body.index('dart setup.dart'))

if __name__ == '__main__':
    unittest.main()
