import base64
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare_oix_dns_auth.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

class PrivateInputTests(unittest.TestCase):
    def test_valid_seed_materializes_without_argv_or_ldflags(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'private.go'
            seed = base64.b64encode(bytes(range(32))).decode()
            prepare.materialize(seed, target)
            text = target.read_text()
            self.assertIn('package oixdnsauth', text)
            self.assertIn('func init()', text)
            self.assertIn(seed, text)

    def test_missing_and_invalid_seed_fails_before_writing(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'private.go'
            for seed in ['', 'bad', base64.b64encode(bytes(31)).decode()]:
                with self.assertRaises(ValueError):
                    prepare.materialize(seed, target)
                self.assertFalse(target.exists())

    def test_private_source_is_gitignored(self):
        ignore = prepare.TARGET.with_name('.gitignore').read_text()
        self.assertIn('private_seed_generated.go', ignore.splitlines())

if __name__ == '__main__':
    unittest.main()
