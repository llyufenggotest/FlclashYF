"""Require compiled startup diagnostics before the unsigned iOS package."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class Wiring(unittest.TestCase):
 def test_compiled_gate_blocks_ipa(self):
  text=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
  self.assertIn('  startup-diagnostics-native:\n',text)
  job=text.split('  startup-diagnostics-native:\n',1)[1].split('\n  ios:\n',1)[0]
  ios=text.split('\n  ios:\n',1)[1].split('\n  macos:\n',1)[0]
  self.assertIn('needs: [verify, swift-review-native, startup-diagnostics-native]',ios)
  self.assertIn('runs-on: macos-15',job)
  self.assertIn('python3 scripts/test_ios_start_diagnostics.py',job)
  self.assertIn('python3 scripts/test_ios_start_diagnostics_swift.py --output',job)
  self.assertNotIn('--prepare-only',job)
  self.assertIn('fetch-depth: 0',job)
  self.assertIn('if: always()',job)
  self.assertIn('uses: actions/upload-artifact@',job)
  self.assertIn('if-no-files-found: error',job)
if __name__=='__main__':unittest.main()
