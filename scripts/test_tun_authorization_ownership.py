"""Execute the complete production requestAdmin body with native/provider boundaries.

No Flutter/pub/Rust hook is used. This complements, not replaces, Riverpod tests.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def method(source):
    start = source.index('  Future<bool> requestAdmin(bool enableTun) async {')
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def run(dart, body, fixture, label, directory):
    target = directory / (label + '.dart')
    target.write_text(fixture.replace('// PRODUCTION_REQUEST_ADMIN', body), encoding='utf-8')
    result = subprocess.run([dart, str(target)], capture_output=True, text=True)
    output = f'{label}: exit={result.returncode}\n{result.stdout}{result.stderr}'
    (directory / (label + '.log')).write_text(output, encoding='utf-8')
    print(output, flush=True)
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default=shutil.which('dart'))
    parser.add_argument('--source', type=pathlib.Path, default=ROOT / 'lib/providers/actions/setup.dart')
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--skip-mutations', action='store_true')
    args = parser.parse_args()
    if not args.dart:
        parser.error('Dart executable required')
    fixture = (ROOT / 'test/fixtures/tun_authorization_boundary.dart.txt').read_text(encoding='utf-8')
    body = method(args.source.read_text(encoding='utf-8'))
    with tempfile.TemporaryDirectory(prefix='tun-auth-') as temporary:
        directory = args.output or pathlib.Path(temporary)
        directory.mkdir(parents=True, exist_ok=True)
        if run(args.dart, body, fixture, 'production', directory):
            return 1
        if not args.skip_mutations:
            mutations = {
                'missing-failure-rollback': body.replace('enable: false', 'enable: true'),
                'missing-intent-ownership': re.sub(r'!identical\([\s\S]*?\)\) \{\s*return true;\s*\}', 'false) { return true; }', body, count=1),
                'missing-disposal-guard': body.replace('!ref.mounted ||', ''),
                'boolean-only-aba-guard': body.replace('!identical(requestedTun, ref.read(patchClashConfigProvider).tun)', '!ref.read(patchClashConfigProvider).tun.enable'),
            }
            for label, mutated in mutations.items():
                if mutated == body:
                    raise AssertionError(f'{label}: mutation did not match; update the gate, never drop it')
                if run(args.dart, mutated, fixture, label, directory) == 0:
                    raise AssertionError(f'{label}: semantic mutation survived')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
