"""Host-only audit of native DNS harness; never substitutes native Swift PASS."""
from pathlib import Path
import hashlib
import io
from contextlib import redirect_stdout
import json
import subprocess
from unittest.mock import patch
import tempfile
import unittest
import test_ios_dns_handoff_swift as gate

class DNSHarnessTests(unittest.TestCase):
    def test_full_bodies_immutable_baseline_and_shared_fixture(self):
        with tempfile.TemporaryDirectory(prefix='dns-handoff-') as d:
            root=Path(d)
            baseline,_=gate.prepare(root,True)
            candidate,_=gate.prepare(root,False)
            self.assertEqual((baseline/'main.swift').read_bytes(),(candidate/'main.swift').read_bytes())
            self.assertEqual((baseline/'dependencies.swift').read_bytes(),(candidate/'dependencies.swift').read_bytes())
            manifest=json.loads((baseline/'sources.json').read_text())
            self.assertEqual(len(manifest)-1,len(gate.PATHS))
            self.assertTrue(all(row['ref']==gate.BASE for row in manifest[:-1]))
            for rel in gate.PATHS:
                raw=(gate.ROOT/rel).read_text()
                expected=gate.integration.transform(raw,rel)
                self.assertEqual((candidate/Path(rel).name).read_text(),expected)
            fixture=(candidate/'main.swift').read_text()
            for case in gate.CASES:
                self.assertIn('"'+case+'"',fixture)
            self.assertIn('controller.start()',fixture)
            self.assertIn('await router.invoke(config)',fixture)
            self.assertIn('manager.connection.starts == 0',fixture)
            self.assertIn('old(#"{"result":true,"error":null}"#)',fixture)

    def test_r1_immutable_production_and_all_original_cases(self):
        with tempfile.TemporaryDirectory(prefix='dns-r1-') as d:
            root = Path(d)
            old, _ = gate.prepare(root, True)
            baseline, _ = gate.prepare(root, True, gate.R1_BASE)
            candidate, _ = gate.prepare(root, False)
            for filename in ['main.swift', 'dependencies.swift']:
                self.assertEqual((old/filename).read_bytes(), (baseline/filename).read_bytes())
                self.assertEqual((baseline/filename).read_bytes(), (candidate/filename).read_bytes())
            manifest = json.loads((baseline/'sources.json').read_text())
            for row in manifest[:-1]:
                self.assertEqual(row['ref'], gate.R1_BASE)
                raw = subprocess.check_output(['git', '-C', str(gate.ROOT), 'show', f"{gate.R1_BASE}:{row['path']}"])
                self.assertEqual(row['sha256'], hashlib.sha256(raw).hexdigest())
                self.assertEqual((baseline/Path(row['path']).name).read_text(), gate.integration.transform(raw.decode(), row['path']))
            self.assertEqual(len(gate.CASES), 16)
            self.assertEqual(gate.CASES[:14], ['suspend-barrier', 'toggle-start', 'superseded-start', 'terminal-stop', 'suspend-false',
                'active-config', 'connecting-config', 'stop-restore', 'stop-failure', 'stale-status',
                'late-resume', 'offline-config', 'resume-false', 'envelopes'])
            self.assertEqual(list(gate.BASELINE_REDS[gate.R1_BASE]), gate.R1_CASES)
            self.assertIn('var preferenceSaves = 0', (candidate/'dependencies.swift').read_text())

    def run_simulated_gate(self, mode):
        # Offline runner wiring test ONLY: no claim of Swift/native execution.
        with tempfile.TemporaryDirectory(prefix='dns-gate-wiring-') as d:
            seen = []
            real_run = subprocess.run
            def run(cmd, **kwargs):
                if cmd[0] == 'git':
                    return real_run(cmd, **kwargs)
                seen.append(cmd)
                if cmd[0] == 'xcrun':
                    self.assertEqual(kwargs['timeout'], 120)
                    self.assertEqual(cmd[cmd.index('-D')+1], 'IOS_ATTEMPT_TESTING')
                    return subprocess.CompletedProcess(cmd, 1 if mode == 'compile-error' else 0, '', 'injected compiler failure' if mode == 'compile-error' else '')
                self.assertEqual(kwargs['timeout'], 25)
                folder, case = Path(cmd[0]).parent.name, cmd[1]
                ref = {'baseline': gate.BASE, 'baseline-r1': gate.R1_BASE}.get(folder)
                if ref:
                    message = gate.BASELINE_REDS[ref][case]
                    if mode == 'wrong-r1-assertion' and ref == gate.R1_BASE:
                        message = f'FAIL DNS {case}: idle suspend not held'
                    return subprocess.CompletedProcess(cmd, 1, message+'\n', '')
                return subprocess.CompletedProcess(cmd, 0, f'PASS DNS {case}\n', '')
            with patch('sys.argv', ['gate', '--output', d]), patch.object(gate.platform, 'system', return_value='Darwin'), \
                 patch.object(gate.shutil, 'which', return_value='xcrun'), patch.object(gate.subprocess, 'run', side_effect=run), \
                 redirect_stdout(io.StringIO()):
                code = gate.main()
            return code, json.loads((Path(d)/'result.json').read_text()), seen

    def test_required_gate_includes_both_r1_reds_and_all_candidate_cases(self):
        code, report, seen = self.run_simulated_gate('success')
        self.assertEqual(code, 0)
        self.assertTrue(report['native_acceptance'])  # Simulated wiring, not native evidence.
        runs = [cmd for cmd in seen if cmd[0] != 'xcrun']
        self.assertEqual([cmd[1] for cmd in runs], ['suspend-barrier'] + gate.R1_CASES + gate.CASES)

    def test_compile_failure_is_not_semantic_red(self):
        code, report, _ = self.run_simulated_gate('compile-error')
        self.assertEqual(code, 3)
        self.assertEqual(report['status'], 'COMPILE_ERROR_NOT_RED')
        self.assertFalse(report['native_acceptance'])

    def test_unrelated_r1_assertion_is_not_expected_red(self):
        code, report, _ = self.run_simulated_gate('wrong-r1-assertion')
        self.assertEqual(code, 1)
        self.assertEqual(report['status'], 'EXPECTED_SEMANTIC_RED_NOT_OBSERVED')
        self.assertFalse(report['native_acceptance'])

if __name__=='__main__':unittest.main()
