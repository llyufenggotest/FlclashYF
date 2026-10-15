"""macOS-only production Swift gates. Compile errors are exit 3, never RED.
Provider baseline de44ae3 must compile and fail a named semantic assertion.
No Swift/Darwin: exit 2 (acceptance BLOCKED). No model counts as native PASS.
"""
import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
BASE = 'de44ae343797f9647466ad34b5758825f0b68d9f'
GROUPS = {
    'provider': ['ios/NECore/PacketTunnelProvider.swift', 'ios/NECore/PacketTunnelLifecycleCleanup.swift'],
    'integration': ['ios/Runner/Tunnel/TunnelController.swift', 'ios/Runner/Tunnel/TunnelManagerStore.swift',
                    'ios/Runner/Tunnel/TunnelCoordinator.swift', 'ios/Runner/Tunnel/TunnelTypes.swift',
                    'ios/Runner/Core/CoreMessageRouter.swift', 'ios/Runner/Core/CoreNotificationCoordinator.swift',
                    'ios/NECore/PacketTunnelCommandServer.swift', 'ios/Shared/ProviderReadRetry.swift'],
}
COMMON = ['ios/NECore/RPCSession.swift', 'ios/NECore/PacketTunnelSharedStateStore.swift', 'ios/Runner/Storage/SharedStateStore.swift']
CASES = {'provider': ['cold-settings-stop', 'quicksetup-stop', 'old-cleanup-new-attempt', 'initial-publish-failure'],
         'integration': ['receipt-codable-owner', 'manager-held-cancel', 'absolute-deadline', 'wrong-reply-owner',
                         'cold-connecting-pending-ready', 'session-replace', 'same-attempt-slot-read',
                         'foreign-obsolete-status', 'legal-disconnect-recovery', 'router-old-app-phase', 'ack-lost-reply']}

def transform(text, path):
    # Only framework imports, bundle/container boundaries change. Production
    # provider/router/manager/controller/receipt method bodies stay intact.
    for module in ['NetworkExtension', 'UIKit', 'WidgetKit']:
        text = text.replace(f'import {module}\n', '')
    text = 'import CoreFoundation\n' + text
    bundle = 'test.attempt.NECore' if path.startswith('ios/NECore/') else 'test.attempt'
    text = text.replace('Bundle.main.bundleIdentifier!', f'"{bundle}"')
    text = text.replace('FileManager.default.containerURL(', 'FileManager.default.testContainerURL(')
    if path.endswith('PacketTunnelProvider.swift') and 'func testCapturedCleanup()' not in text:
        # Baseline observation seam only, no lifecycle behavior substitution.
        text = text.replace('  override func startTunnel(', '  func testCapturedCleanup() -> PacketTunnelLifecycleCleanup? { activeCleanup }\n  override func startTunnel(')
    if path.endswith('RPCSession.swift') and 'testFailNextPublication' not in text:
        # One-shot filesystem fault injection, identical to candidate seam.
        text = text.replace('  @discardableResult\n  func publish(to root: URL?) -> Bool {',
            '  static var testFailNextPublication = false\n  @discardableResult\n  func publish(to root: URL?) -> Bool {\n    if Self.testFailNextPublication { Self.testFailNextPublication = false; return false }')
    return text

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--require-swift', action='store_true')
    args = parser.parse_args()
    swift = shutil.which('swiftc')
    if platform.system() != 'Darwin' or not swift:
        print('NOT EXECUTED: new native provider/router/receipt/manager cases; macOS pending (exit 2)')
        return 2
    with tempfile.TemporaryDirectory(prefix='ios-attempt-fixes-') as tmp:
        tmp = Path(tmp)
        for group, paths in GROUPS.items():
            if args.baseline and group != 'provider':
                continue
            sources = []
            for path in paths + COMMON:
                text = subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{BASE}:{path}'], text=True) if args.baseline else (ROOT/path).read_text(encoding='utf-8')
                target = tmp / Path(path).name
                target.write_text(transform(text, path), encoding='utf-8')
                sources.append(target)
            mainfile = tmp/'main.swift'
            mainfile.write_text((ROOT/f'scripts/fixtures/ios_attempt_fixes_{group}.swift').read_text(encoding='utf-8'), encoding='utf-8')
            binary = tmp/group
            command = [swift, '-swift-version', '5', '-D', 'IOS_ATTEMPT_TESTING', *map(str, sources), str(ROOT/'scripts/fixtures/ios_attempt_fixes_dependencies.swift'), str(mainfile), '-o', str(binary)]
            if group == 'provider':
                command[3:3] = ['-D', 'PROVIDER_FIXTURE']
            built = subprocess.run(command, capture_output=True, text=True, timeout=120)
            print(built.stdout, end=''); print(built.stderr, end='')
            if built.returncode:
                print('COMPILE ERROR: not semantic RED; acceptance BLOCKED')
                return 3
            cases = ['cold-settings-stop', 'initial-publish-failure'] if args.baseline else CASES[group]
            for case in cases:
                out = subprocess.run([str(binary), case], capture_output=True, text=True, timeout=25)
                print(out.stdout, end=''); print(out.stderr, end='')
                if args.baseline:
                    if out.returncode != 1 or f'FAIL NATIVE {case}:' not in out.stdout:
                        print('Baseline must fail the named semantic assertion, not compile/crash/timeout')
                        return 1
                    print(f'CONFIRMED NATIVE RED de44ae3 {case} (not acceptance)')
                elif out.returncode != 0 or f'PASS NATIVE {case}' not in out.stdout:
                    return out.returncode or 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
