"""Portable wiring contracts, not native or device acceptance."""
from pathlib import Path
import argparse
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
BASE = '8f0875977c1ca6a8c35c2ba61159137bf0a507fb'
p = argparse.ArgumentParser()
p.add_argument('--baseline', action='store_true')
a, rest = p.parse_known_args()
def source(rel):
    if a.baseline:
        r = subprocess.run(['git', '-C', str(ROOT), 'show', f'{BASE}:{rel}'], capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else ''
    return (ROOT / rel).read_text(encoding='utf-8')
class TransportContracts(unittest.TestCase):
    def test_official_persisted_and_manual_channel(self):
        manager = source('ios/Runner/Tunnel/TunnelManagerStore.swift')
        coordinator = source('ios/Runner/Tunnel/TunnelCoordinator.swift')
        self.assertIn('proto.providerConfiguration', manager)
        self.assertIn('startVPNTunnel(options:', coordinator)
        self.assertIn('requireStartupEnvelope', coordinator)
    def test_receiver_uses_protocol_before_legacy(self):
        provider = source('ios/NECore/PacketTunnelProvider.swift')
        self.assertIn('protocolConfiguration as? NETunnelProviderProtocol', provider)
        self.assertIn('resolveStartup', provider)
        self.assertIn('loadVPNOptionsSnapshot()', provider)
    def test_envelope_is_bounded_and_closed(self):
        helper = source('ios/Shared/StartupEnvelope.swift').split('// Diagnostic only.', 1)[0]
        for token in ['maxBytes = 32 * 1024', 'version == 1', 'stale_revision', 'CFBooleanGetTypeID', 'UUID(uuidString:', 'options_decode']:
            self.assertIn(token, helper)
        for forbidden in ['config.yaml', 'selected-map', 'test-url', 'home-dir', 'subscription']:
            self.assertNotIn('"' + forbidden + '"', helper)
    def test_active_options_preserves_dart_required_shape(self):
        store = source('ios/Runner/Storage/SharedStateStore.swift')
        self.assertIn('startupSnapshots[revision]', store)
        self.assertNotIn('full.merge(control)', store)
        for key in ['accessControlProps', 'enable', 'allowBypass', 'suspendSupport']:
            self.assertIn('full["' + key + '"] != nil', store)
    def test_bridge_retains_closed_reason(self):
        diag = source('ios/Shared/SwitchDiagnostics.swift')
        for token in ['startupReasons', 'receive_reason', 'receive_source']:
            self.assertIn(token, diag)
    def test_required_mac_gate_and_target_membership(self):
        workflow = source('.github/workflows/ios-five-protocol.yaml')
        job = workflow.split('  startup-diagnostics-native:', 1)[1].split('  ios:', 1)[0]
        self.assertIn('test_ios_startup_transport_swift.py --output', job)
        self.assertIn('${{ runner.temp }}/startup-transport', job)
        self.assertNotIn('--prepare-only', job)
        self.assertIn('needs: [verify, flutter-full, swift-review-native, startup-diagnostics-native]', workflow)
        project = source('ios/Runner.xcodeproj/project.pbxproj')
        for role in ['Runner', 'NECore']:
            self.assertGreaterEqual(project.count('StartupEnvelope.swift in ' + role + ' Sources'), 2)
    def test_later_core_and_owner_gates_preserved(self):
        provider = source('ios/NECore/PacketTunnelProvider.swift')
        for token in ['loadSetupParams()', 'makeInitParams()', 'coreSetupOwner', 'quickSetup', 'commandServer.start', 'RPCSession']:
            self.assertIn(token, provider)
if __name__ == '__main__':
    unittest.main(argv=[__file__, *rest])
