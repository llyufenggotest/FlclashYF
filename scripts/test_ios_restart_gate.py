"""Host-only source/runner contracts. NOT Swift behavior or compilation PASS."""
from pathlib import Path
import importlib.util
import contextlib
import io
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('restart_gate', ROOT / 'scripts/test_ios_restart_swift.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class RestartContracts(unittest.TestCase):
    def setUp(self):
        # Adversarial subprocess doubles must never emit native PASS/RED claims.
        self.capture = contextlib.redirect_stdout(io.StringIO())
        self.capture.__enter__()
        self.addCleanup(self.capture.__exit__, None, None, None)

    def test_timeout_retires_owned_request_without_connected_credit(self):
        source = (ROOT / 'ios/Runner/Tunnel/TunnelCoordinator.swift').read_text(encoding='utf-8')
        body = source.split('private func stopBeforeRestart(', 1)[1].split('private func reconcileStoppedTunnel', 1)[0]
        self.assertIn('case .timeout:', body)
        failure = body.split('case .timeout:', 1)[1].split('case .superseded:', 1)[0]
        self.assertIn('failedRestartGeneration = request.generation', failure)
        self.assertIn('finishTunnelRequest(request, actualState: .stopped)', failure)
        self.assertIn('guard isCurrent(request) else', body)
        self.assertLess(body.index('guard isCurrent(request) else'), body.index('case .timeout:'))
        self.assertIn('if failedRestartGeneration == requestGeneration', source)
        self.assertIn('private let connectTimeout: TimeInterval = 5', source)
        self.assertIn('failedRestartGeneration = nil', source.split('if previousStatus != status', 1)[1])

    def test_required_gate_wiring_and_same_source_methods(self):
        shell = (ROOT / 'scripts/run_ios_attempt_recovery_gate.sh').read_text()
        self.assertIn('python3 scripts/test_ios_restart_gate.py', shell)
        self.assertIn('python3 scripts/test_ios_restart_swift.py', shell)
        fixture = (ROOT / 'scripts/fixtures/ios_restart_main.swift').read_text()
        self.assertNotIn('func stopBeforeRestart', fixture)
        self.assertNotIn('func reconcileRunningTunnel', fixture)
        self.assertNotIn('#if', fixture)
        self.assertIn('await pause(5.6)', fixture)
        self.assertEqual(8, len(set(gate.CASES)))
        for case in gate.CASES:
            self.assertIn('"' + case + '"', fixture)
        source = gate.load_sources(True)
        self.assertEqual(set(gate.PATHS), set(source))
        for text in source.values():
            expected = text.replace('import NetworkExtension\n', '').replace(
                'Bundle.main.bundleIdentifier ?? "cc.chenx.flclash"', '"test.restart"')
            self.assertEqual(expected, gate.adapt_source(text))

    def phase(self, baseline, compiler=0, case_exit=0, stdout=None):
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            if command[0] == 'swiftc':
                return subprocess.CompletedProcess(command, compiler)
            case = command[-1]
            output = stdout if stdout is not None else f'PASS RESTART {case}\n'
            return subprocess.CompletedProcess(command, case_exit, output, '')
        with tempfile.TemporaryDirectory(prefix='restart-contract-') as directory:
            with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(gate, 'load_sources', return_value={p: 'import Foundation\n' for p in gate.PATHS}), mock.patch.object(gate.subprocess, 'run', side_effect=run):
                result = gate.run_phase(Path(directory), 'swiftc', baseline)
        return result, commands

    def test_compiler_failure_is_not_red(self):
        result, commands = self.phase(True, compiler=1)
        self.assertEqual(3, result)
        self.assertEqual(1, len(commands))

    def test_red_requires_exact_behavior_failure_and_exit(self):
        for code, text in [(0, gate.BASELINE_FAILURE), (2, gate.BASELINE_FAILURE),
                           (1, 'FAIL RESTART unrelated'), (1, 'prefix ' + gate.BASELINE_FAILURE)]:
            self.assertEqual(1, self.phase(True, case_exit=code, stdout=text)[0])
        self.assertEqual(0, self.phase(True, case_exit=1, stdout=gate.BASELINE_FAILURE + '\n')[0])

    def test_green_requires_each_actual_pass_marker_and_exit(self):
        for code, text in [(0, ''), (1, 'PASS RESTART coalesced-stop-start')]:
            self.assertEqual(1, self.phase(False, case_exit=code, stdout=text)[0])
        result, commands = self.phase(False)
        self.assertEqual(0, result)
        self.assertEqual(list(gate.CASES), [c[-1] for c in commands[1:]])

    def test_unsupported_hosts_are_not_executed(self):
        for host in ['Windows', 'Linux']:
            with mock.patch.object(gate.platform, 'system', return_value=host), mock.patch.object(gate.shutil, 'which', return_value='swiftc'), mock.patch.object(gate, 'run_phase') as phase:
                self.assertEqual(2, gate.main())
                phase.assert_not_called()

    def test_phase_order_and_red_failure_cannot_reach_green(self):
        for red, expected in [(1, 1), (3, 3), (0, 0)]:
            with mock.patch.object(gate.platform, 'system', return_value='Darwin'), mock.patch.object(gate.shutil, 'which', return_value='swiftc'), mock.patch.object(gate, 'run_phase', side_effect=[red, 0]) as phase:
                self.assertEqual(expected, gate.main())
                self.assertEqual([True, False] if red == 0 else [True], [c.args[2] for c in phase.call_args_list])


if __name__ == '__main__':
    unittest.main(verbosity=2)
