from pathlib import Path
import hashlib
import plistlib
import struct
import sys
import zipfile

EXPECTED = 'cd903ea15657cbd356398adcb60c8872c41c29b69acc1a5dfb78a49d6e75dea5'
DYLIB = 'Frameworks/Tg_@HelloWorld_1024.dylib'


def rpaths(data):
    assert len(data) >= 32, 'truncated Mach-O header'
    magic, cpu, sub, kind, ncmds, size, flags, reserved = struct.unpack_from('<8I', data)
    assert magic == 0xfeedfacf and cpu == 0x100000c, 'expected arm64 Mach-O'
    end = 32 + size
    assert end <= len(data), 'truncated load commands'
    offset = 32
    paths = []
    for _ in range(ncmds):
        assert offset + 8 <= end, 'missing load command'
        cmd, length = struct.unpack_from('<II', data, offset)
        assert length >= 8 and offset + length <= end, 'invalid load command'
        if cmd == 0x8000001c:
            assert length >= 12
            relative = struct.unpack_from('<I', data, offset + 8)[0]
            assert 12 <= relative < length
            value = data[offset + relative:offset + length]
            assert b'\0' in value
            paths.append(value.split(b'\0')[0].decode())
        offset += length
    assert offset == end, 'load command size mismatch'
    return paths


def audit(ipa):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), 'duplicate ZIP members'
        apps = sorted({name.split('/')[1] for name in names
                       if name.startswith('Payload/') and '.app/' in name})
        assert len(apps) == 1, apps
        app = 'Payload/' + apps[0] + '/'
        extensions = {name[len(app + 'PlugIns/'):].split('/')[0] for name in names
                      if name.startswith(app + 'PlugIns/') and '.appex/' in name}
        assert extensions == {'NECore.appex', 'Widget.appex'}, extensions
        targets = [(app, 'Runner', {'@executable_path/Frameworks'}, b'FLCLASH_CORE_VARIANT_FULL'),
                   (app + 'PlugIns/NECore.appex/', 'NECore',
                    {'@executable_path/Frameworks', '@executable_path/../../Frameworks'},
                    b'FLCLASH_CORE_VARIANT_LOWMEM')]
        for base, binary, expected_paths, variant in targets:
            info = plistlib.loads(archive.read(base + 'Info.plist'))
            assert info['CFBundleExecutable'] == binary, info
            path = base + DYLIB
            blob = archive.read(path)
            assert len(blob) == 70368 and hashlib.sha256(blob).hexdigest() == EXPECTED, path
            assert (archive.getinfo(path).external_attr >> 16) & 0o111, path + ' not executable'
            rpaths(blob)
            data = archive.read(base + binary)
            paths = set(rpaths(data))
            assert expected_paths <= paths, (binary, paths)
            assert b'Tg_@HelloWorld_1024.dylib' in data and b'dlopen' in data, binary
            assert variant in data, binary + ' missing build variant evidence'
            other = b'FLCLASH_CORE_VARIANT_LOWMEM' if binary == 'Runner' else b'FLCLASH_CORE_VARIANT_FULL'
            assert other not in data, binary + ' wrong Core variant linked'
            print(binary, 'arm64 packaged dylib hash and Core variant verified; rpaths', sorted(paths))
    print('IPA_ARTIFACT_AUDIT_PASS', ipa)


if __name__ == '__main__':
    audit(sys.argv[1])
