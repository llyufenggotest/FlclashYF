import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from release_manifest_yf import SUFFIXES, build_manifest, stage  # noqa: E402

TAG = 'v0.9.4-yf.1'


def fixture(directory, extra=()):
    for suffix in (*SUFFIXES, *extra):
        (directory / f'FlClash-0.9.4-{suffix}').write_bytes(b'fixture')


class ReleaseManifestTest(unittest.TestCase):
    def test_five_owned_assets_with_size_and_sha(self):
        with tempfile.TemporaryDirectory() as temp:
            dist = Path(temp) / 'dist'
            dist.mkdir()
            fixture(dist, extra=('linux-x64.AppImage', 'macos-x64-v3.dmg'))
            out = Path(temp) / 'release'
            manifest = stage(dist, out, TAG, '- notes',
                             'llyufenggotest/FlclashYF')
            self.assertEqual(len(manifest['assets']), 5)
            self.assertEqual(len(list(out.iterdir())), 6)
            for asset in manifest['assets']:
                self.assertTrue(asset['url'].startswith(
                    'https://github.com/llyufenggotest/FlclashYF/'
                    'releases/download/v0.9.4-yf.1/'))
                self.assertEqual(asset['size'], 7)
                self.assertEqual(len(asset['sha256']), 64)

    def test_rejects_bad_tags_repo_and_missing_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            dist = Path(temp)
            fixture(dist)
            for tag in ('v0.9.4', 'v0.9.4-yf.0', 'v0.9.4-yf.1-rc.1'):
                with self.assertRaises(ValueError):
                    build_manifest(dist, tag, '')
            with self.assertRaises(ValueError):
                build_manifest(dist, TAG, '', 'chenx-dust/FlClash-Patched')
            (dist / 'FlClash-0.9.4-macos-x64.dmg').unlink()
            with self.assertRaises(ValueError):
                build_manifest(dist, TAG, '')

    def test_rejects_empty_asset(self):
        with tempfile.TemporaryDirectory() as temp:
            dist = Path(temp)
            fixture(dist)
            (dist / 'FlClash-0.9.4-ios-arm64-unsigned.ipa').write_bytes(b'')
            with self.assertRaises(ValueError):
                build_manifest(dist, TAG, '')


if __name__ == '__main__':
    unittest.main()
