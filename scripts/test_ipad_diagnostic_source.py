"""Source contracts only; executable Apple behavior gate is separate."""
from pathlib import Path
import argparse, subprocess, unittest
ROOT=Path(__file__).resolve().parents[1]
BASE='de6517d43c3a3277df4f0ce14c42b3f791f9fb05'
BASELINE=False
def read(path):
    return subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:{path}'],text=True) if BASELINE else (ROOT/path).read_text(encoding='utf-8')
class Contracts(unittest.TestCase):
    def test_independent_runner_sink_and_export(self):
        s=read('ios/Shared/SwitchDiagnostics.swift')
        for v in ['iPadDiagnostic-v1','applicationSupportDirectory','maxPendingJobs','maxPendingBytes','runnerLocal','sharedSource','not_proved','exportIPadDiagnostics','NSUnderlyingErrorKey']:
            self.assertIn(v,s)
        channel=read('ios/Runner/ServiceChannel.swift')
        self.assertIn('case "exportIPadDiagnostics":',channel)
        self.assertIn('SwitchDiagnostics.exportIPadDiagnostics',channel)
        dart=read('lib/common/native_log_export.dart')
        self.assertIn("invokeMethod<String>('exportIPadDiagnostics')",dart)
        self.assertLess(dart.index("invokeMethod<String>('exportIPadDiagnostics')"),dart.index('cutoff = await _readCutoff();',dart.index('Future<String> read()')))
    def test_fixed_failure_channel_preserves_underlying(self):
        p=read('ios/NECore/PacketTunnelProvider.swift')
        for v in ['IPadDiagnosticFailure','NSUnderlyingErrorKey: original','originalCompletion(self.diagnosticError','rpc_publication','vpn_options','network_settings','tunnel_fd','quick_setup','start_tun','command_server','cancelled']:
            self.assertIn(v,p)
        self.assertNotIn('startup_failure phase=set_network_settings error=',p)
        self.assertNotIn('startup_failure phase=quick_setup error=',p)
    def test_mac_gate_required_not_replacement(self):
        workflow=read('.github/workflows/ios-five-protocol.yaml')
        for v in ['test_ios_start_diagnostics_swift.py','test_ios_dns_handoff_swift.py','test_ipad_diagnostic_swift.py','${{ runner.temp }}/ipad-diagnostic']:
            self.assertIn(v,workflow)
    def test_loader_same_location_observed_both_processes(self):
        for path in ['ios/Runner/AppDelegate.swift','ios/NECore/PacketTunnelProvider.swift']:
            s=read(path)
            self.assertIn('"ipad_loader_before"',s)
            self.assertIn('"ipad_loader_after"',s)
            self.assertIn('"loader_exists"',s)
            self.assertIn('"loader_loaded"',s)
            self.assertEqual(s.count('dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)'),1)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--baseline',action='store_true');a,rest=parser.parse_known_args();BASELINE=a.baseline
    unittest.main(argv=['ipad-diagnostic',*rest],verbosity=2)
