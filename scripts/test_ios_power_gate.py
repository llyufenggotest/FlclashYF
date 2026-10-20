"""Portable tests for preparation and fail-closed harness behavior, NOT native tests."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('run_ios_power_gate.py')
spec = importlib.util.spec_from_file_location('power_gate', SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PreparationTests(unittest.TestCase):
    def test_baseline_complete_sources_and_count_route(self):
        # Temp directory is owned by this test; no product tree writes.
        with tempfile.TemporaryDirectory(prefix='ios-power-gate-') as temporary:
            out = Path(temporary)
            files, _ = gate.prepare(gate.ROOT, out, 'baseline', gate.BASELINE)
            manifest = json.loads((out / 'baseline/sources.json').read_text())
            self.assertEqual(len(manifest['sources']), 5)
            self.assertTrue(all(row['full_declaration'] for row in manifest['sources']))
            server = next(Path(name).read_text() for name in files if name.endswith('PacketTunnelCommandServer.swift'))
            self.assertEqual(server.count('PowerProbe.bump("enumerate")'), 2)
            self.assertEqual(server.count('PowerProbe.bump("timer")'), 1)
            self.assertIn('timer.setEventHandler { [weak self] in\n        PowerProbe.bump("timer")', server)
            self.assertIn('request.deadline.timeIntervalSinceNow <= 125', server)
            self.assertIn('self.inFlight[id] == token', server)
            self.assertIn('PowerBoundary.containerURL(', next(Path(name).read_text() for name in files if name.endswith('PacketTunnelSharedStateStore.swift')))
            gate.prepare_count(gate.ROOT, out, 'baseline', gate.BASELINE)
            count = json.loads((out / 'baseline-count/sources.json').read_text())
            self.assertEqual(len(count['sources']), 5)
            self.assertTrue(any(row['path'].endswith('CoreMessageRouter.swift') for row in count['sources']))

    def test_observation_seam_refuses_source_drift(self):
        with self.assertRaisesRegex(ValueError, 'must match exactly once'):
            gate.instrument(b'import Foundation\n', 'ios/Shared/SwitchDiagnostics.swift', 'audit')

    def test_no_crash_or_arbitrary_output_is_semantic_red(self):
        for stdout in ['', 'FAIL', '[]', '{"fixture":"made-up"}']:
            with self.subTest(stdout=stdout), self.assertRaises(ValueError):
                gate.semantic_record({'stdout': stdout}, 'p02')

    def test_one_structured_native_row_required(self):
        row = json.dumps({'fixture': 'ios-power-production-v1', 'mode': 'p02', 'status': 'semantic_failure', 'failures': gate.REDS['p02']})
        self.assertEqual(gate.semantic_record({'stdout': row}, 'p02')['failures'], gate.REDS['p02'])
        with self.assertRaises(ValueError):
            gate.semantic_record({'stdout': row + '\n' + row}, 'p02')


if __name__ == '__main__':
    unittest.main()
