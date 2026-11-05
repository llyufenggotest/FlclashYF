"""Portable production wiring contract; native behavior is a separate required gate."""
from pathlib import Path
import subprocess, unittest
ROOT=Path(__file__).resolve().parents[1]
BASE='81e70f1c0c646cc93b2e5f21bcbb4e3926e44817'
class Contract(unittest.TestCase):
 def text(self,p): return (ROOT/p).read_text(encoding='utf-8')
 def test_pre_open_before_core(self):
  s=self.text('ios/NECore/PacketTunnelProvider.swift')
  self.assertLess(s.index('ConfigAccess.observe('),s.index('NECoreBridge.quickSetup('))
  self.assertNotIn('isReadableFile(atPath: root!',s)
 def test_actual_write_bridge(self):
  s=self.text('lib/providers/actions/setup.dart')
  self.assertLess(s.index('safeWriteAsString(yamlString)'),s.index('configAccessWritten'))
  self.assertIn('configAccessWritten',self.text('ios/Runner/ServiceChannel.swift'))
 def test_original_error_not_substring(self):
  s=self.text('core/lib.go'); self.assertIn('quicksetup.Run(',s)
  self.assertIn('handleSetupConfigError',s)
 def test_runner_local_export(self):
  s=self.text('ios/Shared/SwitchDiagnostics.swift')
  self.assertIn('configAccessDecodeFailure',s); self.assertIn('"config_access"',s)
 def test_owner_before_challenge(self):
  s=self.text('ios/Runner/Tunnel/TunnelManagerStore.swift')
  self.assertLess(s.index('else { throw StartupEnvelopeError.stale }'),s.index('ConfigAccess.attach'))
if __name__=='__main__': unittest.main()
