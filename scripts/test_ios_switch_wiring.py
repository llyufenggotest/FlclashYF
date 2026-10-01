#!/usr/bin/env python3
"""Cross-target diagnostic wiring checks; native behavior has separate tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SwitchWiring(unittest.TestCase):
    def test_extension_rpc_boundaries(self):
        source = (ROOT / 'ios/NECore/PacketTunnelProvider.swift').read_text()
        for marker in ['rpc_received', 'rpc_reply', 'rpc_missing_completion',
                       'tunnel_stop', 'tunnel_start']:
            self.assertIn('"' + marker + '"', source)
        self.assertIn('SwitchDiagnostics.requestID(messageData)', source)
        self.assertIn('SwitchDiagnostics.processID', source)
        self.assertLess(
            source.index('NECoreSideloadCompatibilityLoader.loadIfPresent()'),
            source.index('SwitchDiagnostics.record("tunnel_start"'),
        )

    def test_runner_records_process_lifecycle_before_flutter_boot(self):
        source = (ROOT / 'ios/Runner/AppDelegate.swift').read_text()
        self.assertIn('SwitchDiagnostics.recordRunnerLaunch()', source)
        self.assertIn('SwitchDiagnostics.record("app_memory_warning")', source)
        self.assertIn('SwitchDiagnostics.recordRunnerTermination()', source)


    def test_export_includes_both_processes(self):
        provider = (ROOT / 'lib/providers/app.dart').read_text()
        self.assertIn('nativeLogs.read()', provider)
        source = (ROOT / 'lib/common/native_log_export.dart').read_text()
        self.assertIn('ios-switch-Runner.log', source)
        self.assertIn('ios-switch-NECore.log', source)

    def test_go_phase_bridge_in_both_targets(self):
        for path in ['ios/Runner/IOSCoreBridge.m', 'ios/NECore/NECoreBridge.m']:
            source = (ROOT / path).read_text()
            self.assertIn('recordCorePhase:', source)
            self.assertIn('SwitchDiagnostics', source)

    def test_runtime_reply_seeds_route_before_flutter_hydration(self):
        source = (ROOT / 'ios/Runner/ServiceChannel.swift').read_text()
        body = source.split('case "getRunTime":', 1)[1].split('default:', 1)[0]
        self.assertIn('coreMessageRouter.updateTunnelState', body)
        self.assertLess(body.index('coreMessageRouter.updateTunnelState'), body.index('result(runTime)'))

    def test_packaging_runs_native_tests(self):
        source = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text()
        self.assertIn('python3 scripts/test_ios_switch_diagnostics.py', source)
        self.assertIn('python3 scripts/test_ios_provider_retry.py', source)


if __name__ == '__main__':
    unittest.main()
