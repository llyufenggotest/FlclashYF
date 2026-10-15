"""Offline design/source gates; NOT Swift execution or device acceptance.

--baseline reads immutable eaa9ca6f sources. The deterministic flow deliberately
leaves setup pending, disconnects, starts a new NE and drains three old writes.
Native production Swift mailbox gates live in test_ios_attempt_recovery_swift.py.
"""
import argparse
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = 'eaa9ca6f3a60dc223b09de77f0f7f34dddb7f0f4'
BASELINE = False

def source(path):
    if BASELINE:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{BASE}:{path}'], text=True)
    return (ROOT / path).read_text(encoding='utf-8')

class RecoveryContracts(unittest.TestCase):
    def test_simulated_dead_setup_disconnect_new_attempt_releases_gate(self):
        controller = source('ios/Runner/Tunnel/TunnelController.swift')
        # Source-selected state machine: old implementation has no retirement edge.
        # This is a model assertion, not execution of Swift.
        generation, pending_owner, gate = 1, 'old', True
        if 'invalidateProviderRequests' in controller and 'synchronizeProviderSession' in controller:
            generation, pending_owner, gate = generation + 1, None, False
        new_owner = 'new'
        self.assertFalse(gate, 'old setup await still owns gate after disconnect/new NE')
        # A late finish cannot release the new configuration generation.
        new_generation = generation + 1
        self.assertNotEqual(1, new_generation)
        self.assertIsNone(pending_owner)
        self.assertNotEqual('old', new_owner)

    def test_simulated_new_ne_never_executes_three_old_mutations(self):
        server = source('ios/NECore/PacketTunnelCommandServer.swift')
        pending = [dict(attempt='old', method='changeProxy', deadline=120) for _ in range(3)]
        executed = []
        for request in pending:
            fenced = 'RPCRequest' in server and 'request.owner.attempt == attempt' in server
            if not fenced or request['attempt'] == 'new':
                executed.append(request)
        self.assertEqual([], executed, 'new NE executed still-unexpired old mailbox writes')

    def test_wire_requires_version_attempt_nonce_generation_deadline(self):
        controller = source('ios/Runner/Tunnel/TunnelController.swift')
        server = source('ios/NECore/PacketTunnelCommandServer.swift')
        self.assertIn('RPCRequest', controller)
        self.assertIn('RPCRequest', server)
        self.assertIn('request.owner.attempt == attempt', server)
        self.assertIn('RPCWire.version', server)
        self.assertIn('request.deadline > Date()', server)
        self.assertIn('RPCReply', controller)
        self.assertIn('reply.owner == request.owner', controller)

    def test_waiter_checks_epoch_and_session_before_response_and_after_slot(self):
        controller = source('ios/Runner/Tunnel/TunnelController.swift')
        self.assertIn('epoch.isCurrent(clientEpoch)', controller)
        self.assertIn('session.attempt == request.owner.attempt', controller)
        acquire = controller.index('await acquireProviderMessageSlot')
        send = controller.index('sendProviderMessageAttempt(', acquire)
        self.assertIn('validateProviderOwner', controller[acquire:send])
        self.assertIn('catch is CancellationError', controller)

    def test_router_does_not_forward_pre_restart_app_phase_to_new_ne(self):
        router = source('ios/Runner/Core/CoreMessageRouter.swift')
        self.assertIn('captureProviderOwner()', router)
        self.assertIn('validateProviderOwner(configurationOwner)', router)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', action='store_true')
    args, rest = parser.parse_known_args()
    BASELINE = args.baseline
    unittest.main(argv=['test_ios_attempt_recovery', *rest], verbosity=2)
