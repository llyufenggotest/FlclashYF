#!/usr/bin/env python3
"""Cross-target diagnostic wiring checks; native behavior has separate tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SwitchWiring(unittest.TestCase):
    def test_extension_rpc_boundaries(self):
        source = (ROOT / 'ios/NECore/PacketTunnelProvider.swift').read_text()
        for marker in ['rpc_received', 'rpc_reply', 'rpc_missing_completion',
                       'tunnel_stop', 'tunnel_sleep', 'tunnel_wake', 'tunnel_start']:
            self.assertIn('"' + marker + '"', source)
        self.assertIn('SwitchDiagnostics.requestID(messageData)', source)
        self.assertIn('SwitchDiagnostics.processID', source)

    def test_export_includes_both_processes(self):
        source = (ROOT / 'lib/providers/app.dart').read_text()
        self.assertIn('ios-switch-Runner.log', source)
        self.assertIn('ios-switch-NECore.log', source)

    def test_go_phase_bridge_in_both_targets(self):
        for path in ['ios/Runner/IOSCoreBridge.m', 'ios/NECore/NECoreBridge.m']:
            source = (ROOT / path).read_text()
            self.assertIn('recordCorePhase:', source)
            self.assertIn('SwitchDiagnostics', source)

    def test_packaging_runs_native_tests(self):
        source = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text()
        self.assertIn('python3 scripts/test_ios_switch_diagnostics.py', source)


if __name__ == '__main__':
    unittest.main()
