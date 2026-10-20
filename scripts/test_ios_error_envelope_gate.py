"""Portable preparation/contract tests, not native execution claims."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
class ErrorGateTests(unittest.TestCase):
    def test_pinned_red_and_native_only(self):
        gate=load('run_ios_error_envelope_gate')
        self.assertEqual(gate.BASELINE,'e502b9ce2b18bfebba550495f568f7f61e64f3da')
        self.assertEqual(gate.PRE_FIX,'fa94ff59cffe7e540b2119aa3f3900517423effb')
        self.assertEqual(gate.FAILURE,['core_error_reply_detail_coalesced'])
        self.assertIn(b'wire_error_changed',gate.fixture(ROOT))
        self.assertIn(b'wire_owner_changed',gate.fixture(ROOT))
    def test_production_chain_preparation_and_one_decoder_seam(self):
        gate=load('run_ios_error_chain_gate')
        with tempfile.TemporaryDirectory() as tmp:
            for group in ['provider','integration']:
                folder,files=gate.prepare(ROOT,Path(tmp),group)
                source=(folder/'SwitchDiagnostics.swift').read_text()
                self.assertEqual(source.count('PowerProbe.bump("response_decode")'),1)
                self.assertNotIn('enum SwitchDiagnostics {',(folder/'dependencies.swift').read_text())
                self.assertIn('PacketTunnelProvider.swift' if group=='provider' else 'CoreMessageRouter.swift',','.join(files))
    def test_minimal_bounded_classification_no_payload_storage(self):
        source=(ROOT/'ios/Shared/SwitchDiagnostics.swift').read_text()
        seam=source.split('static func responseErrorType(_ data: Data?',1)[1].split('// Only successful routine',1)[0]
        self.assertIn('data.count <= 4096',seam)
        self.assertIn('prefix(4097)',seam)
        self.assertIn('case error',seam)
        self.assertNotIn('JSONSerialization',seam)
        self.assertNotIn('message:',seam)
        router=(ROOT/'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        ne=router.split('// Reuse the Runner ingress classification;',1)[1].split('} catch {',1)[0]
        self.assertNotIn('responseErrorType(',ne)
        self.assertIn('diagnosticReply:',ne)
if __name__=='__main__':unittest.main()
