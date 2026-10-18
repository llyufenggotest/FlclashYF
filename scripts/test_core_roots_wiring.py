"""Fail closed if YF packaging omits the core CA asset."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoreRootsWiringTests(unittest.TestCase):
    def test_each_yf_build_stages_the_same_core_ca_bundle(self):
        text = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text(encoding='utf-8')
        jobs = dict(re.findall(r'^  ([a-zA-Z0-9_-]+):\n(.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)', text.split('jobs:', 1)[1], re.M | re.S))
        for job in ('android', 'windows', 'ios', 'macos'):
            with self.subTest(job=job):
                body = jobs[job]
                self.assertIn('name: Fetch CA certificates', body)
                self.assertIn('https://curl.se/ca/cacert.pem', body)
                self.assertIn('core/mihomo/component/ca/ca-certificates.crt', body)
                self.assertIn('test "$count" -ge 100', body)
                self.assertIn('cp "$bundle" assets/data/ca-certificates.crt', body)
                self.assertLess(body.index('name: Fetch CA certificates'), body.index('dart setup.dart'))


if __name__ == '__main__':
    unittest.main()
