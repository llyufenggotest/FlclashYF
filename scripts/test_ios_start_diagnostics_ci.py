"""Require compiled startup diagnostics before the unsigned iOS package."""
from pathlib import Path
from contextlib import redirect_stdout
import io
import unittest
from unittest.mock import patch
import test_ios_swift_review_source as review_source
ROOT=Path(__file__).resolve().parents[1]
class Wiring(unittest.TestCase):
 def test_compiled_gate_blocks_ipa(self):
  text=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
  self.assertIn('  startup-diagnostics-native:\n',text)
  job=text.split('  startup-diagnostics-native:\n',1)[1].split('\n  ios:\n',1)[0]
  ios=text.split('\n  ios:\n',1)[1].split('\n  macos:\n',1)[0]
  self.assertIn('needs: [verify, flutter-full, swift-review-native, startup-diagnostics-native]',ios)
  self.assertIn('runs-on: macos-15',job)
  self.assertIn('python3 scripts/test_ios_start_diagnostics.py',job)
  self.assertIn('python3 scripts/test_ios_start_diagnostics_swift.py --output',job)
  self.assertNotIn('--prepare-only',job)
  self.assertIn('fetch-depth: 0',job)
  self.assertIn('if: always()',job)
  self.assertIn('uses: actions/upload-artifact@',job)
  self.assertIn('if-no-files-found: error',job)
 def review_accepts(self, packaging):
  original=Path.read_text
  def read(path, *args, **kwargs):
   if path == ROOT/'.github/workflows/ios-five-protocol.yaml':
    return packaging
   return original(path, *args, **kwargs)
  with patch.object(Path, 'read_text', new=read), redirect_stdout(io.StringIO()):
   return review_source.check_tree()
 def test_review_accepts_additive_required_native_gate(self):
  text=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
  self.assertTrue(self.review_accepts(text))
 def test_review_rejects_missing_original_dependencies(self):
  text=(ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
  for missing in ('verify', 'swift-review-native'):
   with self.subTest(missing=missing):
    dependencies=[name for name in ('verify', 'flutter-full', 'swift-review-native', 'startup-diagnostics-native') if name != missing]
    changed=text.replace('needs: [verify, flutter-full, swift-review-native, startup-diagnostics-native]', 'needs: ['+', '.join(dependencies)+']')
    self.assertNotEqual(text,changed)
    self.assertFalse(self.review_accepts(changed))
if __name__=='__main__':unittest.main()
