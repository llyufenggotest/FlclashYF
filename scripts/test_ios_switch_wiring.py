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

    def test_restoration_signatures_and_runtime_node_traffic(self):
        controller = (ROOT / 'ios/Runner/Tunnel/TunnelController.swift').read_text()
        self.assertIn('onConnectionStateChanged: @escaping (String) -> Void', controller)
        self.assertIn('onConnectionStateChanged: onConnectionStateChanged', controller)
        self.assertIn('func publishConnectionState()', controller)
        self.assertIn('coordinator.publishConnectionState()', controller)
        router = (ROOT / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        runtime = router.split('private enum RuntimeStateCoreMethod', 1)[1].split('private struct', 1)[0]
        self.assertIn('case getNodeTraffic', runtime)
        retry = (ROOT / 'ios/Shared/ProviderReadRetry.swift').read_text()
        self.assertIn('"getNodeTraffic"', retry)

    def test_tun_options_and_sleep_do_not_suspend(self):
        provider = (ROOT / 'ios/NECore/PacketTunnelProvider.swift').read_text()
        self.assertIn('congestionController: vpnOptions.congestionController', provider)
        self.assertIn('let congestionController: String', provider)
        self.assertNotIn('NECoreBridge.setSuspended', provider)
        self.assertNotIn('vpnOptions.suspendSupport', provider)

    def test_file_rpc_configuration_acknowledgment(self):
        source = (ROOT / 'ios/NECore/PacketTunnelCommandServer.swift').read_text()
        self.assertIn('sharedStateStore.clearConfigurationRequestApplied()', source)
        self.assertIn('self.sharedStateStore.markConfigurationRequestApplied(requestID)', source)
        self.assertLess(source.index('clearConfigurationRequestApplied()'), source.index('invoke(data)'))
        self.assertLess(source.index('markConfigurationRequestApplied(requestID)'), source.index('self.writeResponse(id: id'))
        self.assertIn('result.isEmpty', source)
        self.assertIn('object["error"] is NSNull', source)

    def test_packaging_runs_native_tests(self):
        source = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text()
        self.assertIn('python3 scripts/test_ios_switch_diagnostics.py', source)
        self.assertIn('python3 scripts/test_ios_provider_retry.py', source)


if __name__ == '__main__':
    unittest.main()
