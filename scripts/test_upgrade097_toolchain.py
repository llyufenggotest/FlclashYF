"""Keep the custom five-platform matrix on the donor release toolchain."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class Upgrade097ToolchainTests(unittest.TestCase):
    def test_custom_matrix_matches_upstream_release_pins(self):
        donor = (ROOT / '.github/workflows/build.yaml').read_text(encoding='utf-8')
        matrix = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text(encoding='utf-8')
        for key in ('GO_VERSION', 'FLUTTER_VERSION', 'NDK_VERSION'):
            with self.subTest(pin=key):
                pattern = rf'^  {key}:\s*[\"\x27]?([^\"\x27\s]+)'
                expected = re.search(pattern, donor, re.M)
                actual = re.search(pattern, matrix, re.M)
                self.assertIsNotNone(expected)
                self.assertIsNotNone(actual)
                self.assertEqual(expected.group(1), actual.group(1))


if __name__ == '__main__':
    unittest.main()
