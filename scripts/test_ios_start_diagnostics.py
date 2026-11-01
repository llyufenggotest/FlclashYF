"""Portable source contracts only; native behavior is a separate Mac gate."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class StartDiagnosticsContracts(unittest.TestCase):
    def test_terminal_failure_is_sampled_at_owned_start_wait(self):
        source = (ROOT/'ios/Runner/Tunnel/TunnelCoordinator.swift').read_text()
        body = source.split('private func consumeWaitStatus(', 1)[1].split('private func resolveTunnelWait(', 1)[0]
        self.assertIn('status == .connecting', body)
        self.assertIn('captureLastStartDisconnect(wait)', body)
        seam = source.split('private func captureLastStartDisconnect(', 1)[1].split('private func resolveTunnelWait(', 1)[0]
        for text in ['wait.purpose == .starting', 'isCurrent(wait.request)',
                     'diagnosticConnectingGeneration == generation',
                     'diagnosticFetchedGeneration != generation',
                     'fetchLastDisconnectError', '#available(iOS 16.0, macOS 13.0, *)',
                     'self.requestGeneration == generation', 'SwitchDiagnostics.disconnectErrorFields(error)',
                     '"stage": "start_tunnel"', '"generation": String(generation)']:
            self.assertIn(text, seam)
        for text in ['await ', 'stopVPNTunnel', 'startVPNTunnel', 'localizedDescription', 'userInfo', 'reset']:
            self.assertNotIn(text, seam)

    def test_real_envelope_and_bounded_result_classification(self):
        core = (ROOT/'core/method.go').read_text()
        delay = (ROOT/'core/constant.go').read_text()
        self.assertIn('`json:"error,omitempty"`', core)
        self.assertIn('Value int32  `json:"value"`', delay)
        source = (ROOT/'ios/Shared/SwitchDiagnostics.swift').read_text()
        seam = source.split('static func responseErrorType(_ data: Data?', 1)[1].split('// Only successful routine', 1)[0]
        for text in ['"asyncTestDelay"', 'data.count <= 4096', 'prefix(4097)',
                     'container.contains(.error)', 'case error', 'Int32',
                     'delay_positive', 'delay_negative', 'delay_missing', 'delay_invalid']:
            self.assertIn(text, seam)
        for text in ['JSONSerialization', 'localizedDescription', 'userInfo', 'let name', 'let url']:
            self.assertNotIn(text, seam)
        self.assertIn('guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {', seam)

    def test_native_preparation_preserves_production_bodies_and_blocks_windows(self):
        import importlib.util
        import tempfile
        import contextlib
        import io
        from unittest import mock
        spec = importlib.util.spec_from_file_location('start_gate', ROOT/'scripts/test_ios_start_diagnostics_swift.py')
        gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
        with tempfile.TemporaryDirectory() as tmp:
            folder, files = gate.prepare(Path(tmp))
            source = (ROOT/'ios/Runner/Tunnel/TunnelCoordinator.swift').read_text()
            self.assertEqual((folder/'TunnelCoordinator.swift').read_text(), source.replace('import NetworkExtension\n',''))
            fixture = (folder/'main.swift').read_text()
            self.assertIn('pendingDisconnect.append(completionHandler)', fixture)
            self.assertNotIn('func consumeWaitStatus', fixture)
            for case in gate.CASES:
                self.assertIn(case, fixture if case != 'immediate-failure' else str(gate.CASES))
            red, _ = gate.prepare_payload_red(Path(tmp))
            baseline = (red/'main.swift').read_text()
            self.assertIn('delay classification', baseline)
            self.assertNotIn('Task { @MainActor in', baseline)
        with tempfile.TemporaryDirectory() as tmp, mock.patch('sys.argv',['gate','--output',tmp]), mock.patch.object(gate.platform,'system',return_value='Windows'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            import json
            report = json.loads((Path(tmp)/'result.json').read_text())
            self.assertFalse(report['native_acceptance'])
            self.assertEqual(report['executions'], [])
            import subprocess
            head = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
            self.assertEqual(report.get('candidate_head'), head)

    def test_error_persistence_has_closed_domain_and_signed_code(self):
        source = (ROOT/'ios/Shared/SwitchDiagnostics.swift').read_text()
        self.assertIn('"tunnel_start_disconnect_error"', source)
        seam = source.split('static func disconnectErrorFields(', 1)[1].split('// Only successful routine', 1)[0]
        self.assertIn('"unknown"', seam)
        self.assertIn('error.code', seam)
        self.assertNotIn('localizedDescription', seam)
        self.assertNotIn('userInfo', seam)
        self.assertIn('case "error_code":', source)
        self.assertIn('Int64(value)', source)

if __name__ == '__main__':
    unittest.main()
