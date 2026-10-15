"""Compile real Swift controller/bridge/server; doubles only Apple/app/core deps.

No Swift => exit 2, never native PASS. --baseline must reach a semantic FAIL
(exit 1), never count compiler failures as RED. On macOS invoke in CI before IPA.
The full Runner/UIKit/NECore build is a separate mandatory acceptance gate.
"""
import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 'eaa9ca6f3a60dc223b09de77f0f7f34dddb7f0f4'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--require-swift', action='store_true')
    args = parser.parse_args()
    swift = shutil.which('swiftc')
    if not swift or platform.system() != 'Darwin':
        print('NOT EXECUTED: macOS Swift attempt-recovery native RED/GREEN pending (exit 2)')
        return 2
    with tempfile.TemporaryDirectory(prefix='ios-attempt-') as directory:
        directory = Path(directory)
        sources = []
        paths = ['ios/Runner/Tunnel/TunnelController.swift',
                 'ios/NECore/PacketTunnelCommandServer.swift']
        for path in paths:
            text = (subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{BASE}:{path}'], text=True)
                    if args.baseline else (ROOT / path).read_text())
            # Compile unchanged method bodies. Imports and the bundle-ID
            # dependency are substituted; Apple/framework dependencies are doubles.
            text = text.replace('import UIKit\n', '').replace('import NetworkExtension\n', '')
            text = text.replace('Bundle.main.bundleIdentifier!', '"test.attempt"')
            target = directory / Path(path).name
            target.write_text(text)
            sources.append(target)
        sources += [ROOT / 'ios/NECore/RPCSession.swift', ROOT / 'ios/Shared/ProviderReadRetry.swift']
        mainfile = directory / 'main.swift'
        mainfile.write_bytes((ROOT / 'scripts/fixtures/ios_attempt_recovery_main.swift').read_bytes())
        binary = directory / 'attempt'
        command = [swift, '-swift-version', '5', '-D', 'IOS_ATTEMPT_TESTING']
        if args.baseline:
            command += ['-D', 'ATTEMPT_BASELINE']
        subprocess.run([*command, *map(str, sources), str(mainfile), '-o', str(binary)], check=True, timeout=120)
        out = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)
        print(out.stdout, end=''); print(out.stderr, end='')
        if args.baseline:
            if out.returncode != 1 or 'FAIL ATTEMPT: new NE executed 3 old mutations' not in out.stdout:
                raise SystemExit('Expected semantic compiled baseline RED not established')
            print('CONFIRMED immutable eaa9ca6f native RED (not product acceptance)')
            return 0
        if out.returncode != 0 or 'PASS ATTEMPT real Swift' not in out.stdout:
            return out.returncode or 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
