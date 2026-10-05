import contextlib
import io
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile
from audit_ipa_artifact import audit, rpaths

ROOT = Path(__file__).resolve().parents[1]


def macho(paths, marker=b''):
    commands = []
    for path in paths:
        value = path.encode() + b'\0'
        size = (12 + len(value) + 7) // 8 * 8
        commands.append(struct.pack('<III', 0x8000001c, size, 12) + value + bytes(size - 12 - len(value)))
    body = b''.join(commands)
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, len(commands), len(body), 0, 0) + body + marker


class AuditTests(unittest.TestCase):
    def fixture(self, path, *, wrong_variant=False, missing_rpath=False, corrupt=False):
        dylib = (ROOT / 'ios/SideloadSupport/Tg_@HelloWorld_1024.dylib').read_bytes()
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Runner.app/PlugIns/Widget.appex/Info.plist',
                             plistlib.dumps({'CFBundleExecutable': 'Widget'}))
            for base, executable, paths, variant in [
                ('Payload/Runner.app/', 'Runner', ['@executable_path/Frameworks'], b'FLCLASH_CORE_VARIANT_FULL'),
                ('Payload/Runner.app/PlugIns/NECore.appex/', 'NECore', ['@executable_path/Frameworks', '@executable_path/../../Frameworks'], b'FLCLASH_CORE_VARIANT_LOWMEM'),
            ]:
                if executable == 'NECore' and wrong_variant:
                    variant = b'FLCLASH_CORE_VARIANT_FULL'
                if executable == 'NECore' and missing_rpath:
                    paths = paths[:1]
                archive.writestr(base + 'Info.plist', plistlib.dumps({'CFBundleExecutable': executable}))
                archive.writestr(base + executable, macho(paths, variant + b'Tg_@HelloWorld_1024.dylib dlopen'))
                member = zipfile.ZipInfo(base + 'Frameworks/Tg_@HelloWorld_1024.dylib')
                member.external_attr = 0o100755 << 16
                archive.writestr(member, dylib[:-1] if corrupt else dylib)

    def test_fixture_and_negative_contracts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic-fixture.ipa'
            self.fixture(path)
            with contextlib.redirect_stdout(io.StringIO()):
                audit(path)
                for flags in [{'wrong_variant': True}, {'missing_rpath': True}, {'corrupt': True}]:
                    self.fixture(path, **flags)
                    with self.assertRaises(AssertionError):
                        audit(path)

    def test_truncated_command_is_rejected(self):
        data = macho(['@executable_path/Frameworks'])
        with self.assertRaises(AssertionError):
            rpaths(data[:-1])


if __name__ == '__main__':
    unittest.main()
