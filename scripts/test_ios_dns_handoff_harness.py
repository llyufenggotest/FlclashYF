"""Host-only audit of native DNS harness; never substitutes native Swift PASS."""
from pathlib import Path
import hashlib
import json
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

if __name__=='__main__':unittest.main()
