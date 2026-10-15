"""Review regression contracts: source-derived checks, NOT native Swift PASS.
Immutable de44ae3 must fail these contracts before implementation.
"""
import argparse
from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
BASE = 'de44ae343797f9647466ad34b5758825f0b68d9f'
BASELINE = False

def source(path):
    return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{BASE}:{path}'], text=True) if BASELINE else (ROOT / path).read_text(encoding='utf-8')

class AttemptFixContracts(unittest.TestCase):
    def test_r1_cleanup_owns_immutable_attempt(self):
        p = source('ios/NECore/PacketTunnelProvider.swift')
        cleanup = p.split('private func makeLifecycleCleanup', 1)[1].split('override func startTunnel', 1)[0]
        self.assertIn('ownedAttempt: UUID', cleanup)
        self.assertIn('attempt == ownedAttempt', cleanup)
        self.assertNotIn('attempt == self.lifecycleGeneration', cleanup)

    def test_r2_filter_before_invalidation(self):
        c = source('ios/Runner/Tunnel/TunnelController.swift')
        observer = c.split('forName: .NEVPNStatusDidChange', 1)[1].split('if appActiveObserver', 1)[0]
        self.assertLess(observer.index('isManagedConnection'), observer.index('invalidateProviderRequests()'))
        self.assertLess(observer.index('ownsStatusConnection'), observer.index('invalidateProviderRequests()'))
        self.assertIn('notificationEpoch', observer)
        self.assertIn('notificationAttempt', observer)

    def test_r3_absolute_deadline_and_manager_cancellation(self):
        c = source('ios/Runner/Tunnel/TunnelController.swift')
        a = c.split('private func sendProviderMessageAttempt', 1)[1].split('private func acquireProviderMessageSlot', 1)[0]
        self.assertIn('deadline: Date', a)
        self.assertIn('deadline: deadline', a)
        bridge = c.split('actor ProviderMessageBridge', 1)[1]
        self.assertIn('deadline: Date', bridge)
        self.assertNotIn('deadline: Date().addingTimeInterval(timeout)', bridge)
        m = source('ios/Runner/Tunnel/TunnelManagerStore.swift')
        self.assertIn('withTaskCancellationHandler', m)
        self.assertIn('cancelManagerLoadRequest', m)

    def test_r3_slot_captures_config_generation_before_wait(self):
        c = source('ios/Runner/Tunnel/TunnelController.swift')
        send = c.split('func sendProviderMessage(_ data: Data)', 1)[1].split('private func sendProviderMessageAttempt', 1)[0]
        self.assertLess(send.index('let generation = configurationGeneration'), send.index('await acquireProviderMessageSlot'))
        self.assertIn('configurationGeneration: retryRead ? generation : nil', send)

    def test_r4_initial_publish_is_required_after_completion_installed(self):
        p = source('ios/NECore/PacketTunnelProvider.swift')
        start = p.split('override func startTunnel', 1)[1].split('override func stopTunnel', 1)[0]
        self.assertIn('guard RPCSession', start)
        self.assertLess(start.index('pendingStartupCompletion = completionHandler'), start.index('guard RPCSession'))
        guard = start.split('guard RPCSession', 1)[1].split('logger.info("startTunnel begin")', 1)[0]
        self.assertIn('completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)', guard)
        self.assertIn('return', guard)

    def test_r5_real_provider_router_and_store_contracts(self):
        provider = source('ios/NECore/PacketTunnelProvider.swift')
        router = source('ios/Runner/Core/CoreMessageRouter.swift')
        runner_store = source('ios/Runner/Storage/SharedStateStore.swift')
        provider_store = source('ios/NECore/PacketTunnelSharedStateStore.swift')
        server = source('ios/NECore/PacketTunnelCommandServer.swift')
        self.assertIn('makeLifecycleCleanup(ownedAttempt: UUID)', provider)
        self.assertIn('guard RPCSession(version:', provider)
        self.assertIn('captureProviderOwner()', router)
        self.assertIn('validateProviderOwner(configurationOwner)', router)
        self.assertIn('JSONDecoder().decode(RPCAppliedReceipt.self', runner_store)
        self.assertIn('receipt.owner == owner', runner_store)
        self.assertIn('JSONEncoder().encode(RPCAppliedReceipt(', provider_store)
        self.assertIn('session.attempt == owner.attempt', provider_store)
        self.assertIn('markConfigurationRequestApplied(requestID, owner: request.owner)', server)

    def test_r5_macos_gate_blocks_ipa_workflow(self):
        workflow = source('.github/workflows/ios-five-protocol.yaml')
        gate = source('scripts/run_ios_attempt_recovery_gate.sh')
        self.assertIn('bash scripts/run_ios_attempt_recovery_gate.sh', workflow)
        self.assertIn('python3 scripts/test_ios_attempt_fixes.py', gate)
        self.assertIn('test_ios_attempt_recovery_swift.py --baseline --require-swift', gate)
        self.assertIn('test_ios_attempt_recovery_swift.py --require-swift', gate)
        self.assertIn('python3 scripts/test_ios_attempt_fixes_swift.py --baseline --require-swift', gate)
        self.assertIn('python3 scripts/test_ios_attempt_fixes_swift.py --require-swift', gate)
        self.assertIn('set -euo pipefail', gate)

    def test_native_gate_declares_all_required_production_cases(self):
        import runpy
        gate = runpy.run_path(str(ROOT / 'scripts/test_ios_attempt_fixes_swift.py'))
        expected = {'cold-settings-stop', 'quicksetup-stop', 'old-cleanup-new-attempt',
                    'initial-publish-failure', 'receipt-codable-owner', 'manager-held-cancel',
                    'absolute-deadline', 'wrong-reply-owner', 'cold-connecting-pending-ready',
                    'session-replace', 'same-attempt-slot-read', 'foreign-obsolete-status',
                    'legal-disconnect-recovery', 'router-old-app-phase', 'ack-lost-reply'}
        self.assertEqual(expected, {case for cases in gate['CASES'].values() for case in cases})
        for group, cases in gate['CASES'].items():
            fixture = (ROOT / f'scripts/fixtures/ios_attempt_fixes_{group}.swift').read_text(encoding='utf-8')
            for case in cases:
                # cold-settings-stop is the provider's default cold path.
                if case != 'cold-settings-stop': self.assertIn(case, fixture)
        sources = {path for paths in gate['GROUPS'].values() for path in paths} | set(gate['COMMON'])
        for path in ['ios/NECore/PacketTunnelProvider.swift', 'ios/Runner/Core/CoreMessageRouter.swift',
                     'ios/NECore/PacketTunnelSharedStateStore.swift', 'ios/Runner/Storage/SharedStateStore.swift',
                     'ios/Runner/Tunnel/TunnelManagerStore.swift']:
            self.assertIn(path, sources)

    def test_native_compile_failure_cannot_count_as_red(self):
        import runpy
        import unittest.mock as mock
        gate = runpy.run_path(str(ROOT / 'scripts/test_ios_attempt_fixes_swift.py'))
        commands = []
        def compiler_failure(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 1, '', 'synthetic compiler failure (control-flow test only)')
        with mock.patch('platform.system', return_value='Darwin'), mock.patch('shutil.which', return_value='swiftc'), mock.patch('sys.argv', ['gate', '--baseline']), mock.patch('subprocess.run', side_effect=compiler_failure):
            self.assertEqual(3, gate['main']())
        swift_commands = [command for command in commands if command and command[0] == 'swiftc']
        self.assertEqual(['-D', 'PROVIDER_FIXTURE', '-D', 'IOS_ATTEMPT_TESTING'], swift_commands[0][3:7])

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', action='store_true')
    args, rest = parser.parse_known_args()
    BASELINE = args.baseline
    unittest.main(argv=['attempt-fixes', *rest], verbosity=2)
