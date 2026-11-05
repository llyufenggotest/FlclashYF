"""Source contracts only; native execution is the separate mandatory Mac gate."""
from pathlib import Path
import argparse, subprocess, unittest
ROOT = Path(__file__).resolve().parents[1]
BASE = '6a95950d54b4e1fefe3507b0730ebeab95d9095c'
p = argparse.ArgumentParser(); p.add_argument('--baseline', action='store_true'); args, rest = p.parse_known_args()
def source(path):
    if args.baseline:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{BASE}:{path}'], text=True)
    return (ROOT/path).read_text(encoding='utf-8')
class ReviewFix(unittest.TestCase):
    def test_R1_budget_not_arbitrary_count(self):
        text = source('ios/Shared/StartupEnvelope.swift')
        self.assertNotIn('items.count <= 256', text)
        self.assertIn('maxBytes = 32 * 1024', text)
        self.assertIn('value as? [String]', text)
        self.assertIn('bytes.count <= maxBytes', text)
    def test_R2_active_receipt_not_desired_reconstruction(self):
        text = source('ios/Runner/Storage/SharedStateStore.swift')
        getter = text.split('func activeVpnOptions()', 1)[1].split('private var startupEnvelope', 1)[0]
        self.assertNotIn('sharedStateJSON', getter)
        self.assertNotIn('full.merge', getter)
        self.assertIn('activeStartupRevision', getter)
        self.assertIn('startupSnapshots', getter)
        self.assertIn('envelope.options == active', getter)
        self.assertIn('UserDefaults.standard', text)
        provider = source('ios/NECore/PacketTunnelProvider.swift')
        self.assertIn('revision: startupRevision', provider)
        receiver = source('ios/NECore/PacketTunnelSharedStateStore.swift')
        self.assertIn('activeStartupRevision', receiver)
    def test_mandatory_gate_preserves_original_probe_and_red_oracles(self):
        import hashlib
        original = ROOT/'scripts/fixtures/startup_review_original.swift'
        self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), '8b5a912e9f8b8e073db61ca0255e4aba544cb66fd7cba2ca13c0e2fb8130093c')
        workflow = (ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
        job = workflow.split('  startup-diagnostics-native:', 1)[1].split('  ios:', 1)[0]
        self.assertIn('test_ios_startup_review_fix_swift.py --output', job)
        self.assertIn('${{ runner.temp }}/startup-review-fix', job)
        self.assertNotIn('--prepare-only', job)
        gate = (ROOT/'scripts/test_ios_startup_review_fix_swift.py').read_text()
        self.assertIn(BASE, gate)
        self.assertIn("COMPILE_ERROR_NOT_RED", gate)
        self.assertIn("run.returncode!=1", gate)
        self.assertIn("native_acceptance=False", gate)
    def test_direct_caller_failure_semantics_unchanged(self):
        text = source('lib/manager/vpn_manager.dart')
        self.assertIn('if (active == null || options == null) return;', text)
        self.assertIn('if (options == active)', text)
        self.assertIn('vpnConfigChangeDetected', text)
if __name__ == '__main__': unittest.main(argv=[__file__, *rest])
