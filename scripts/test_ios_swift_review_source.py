"""Supplemental fail-closed source gates, NOT native compile/behavior evidence."""
import argparse
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]

def check_tree(ref=None):
    def read(path):
        if ref:
            return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT, text=True)
        return (ROOT / path).read_text(encoding='utf-8')
    log = read('ios/NECore/NativeDiagnosticLog.swift')
    event = read('ios/NECore/NECoreEventQueue.swift')
    bridge = read('ios/NECore/NECoreBridge.m')
    runner = read('ios/Runner/Core/CoreEventRelay.swift')
    provider = read('ios/NECore/PacketTunnelProvider.swift')
    script = read('scripts/test_ios_memory_round2.py')
    workflow = read('.github/workflows/ios-memory-native.yaml')
    packaging = read('.github/workflows/ios-five-protocol.yaml')
    tests = [
        ('M01 no synchronous diagnostic admission', 'queue.sync { write(data) }' not in log),
        ('M01 reserved critical diagnostic budget and counters', 'maxCriticalJobs' in log and 'droppedCritical' in log),
        ('M01 production main never flushes writer', 'NativeDiagnosticLog.shared.flush()' not in provider),
        ('M01 GC retirement keeps owner closed', 'coreReclaimRetiring' in provider and 'resourceHeartbeat.retire' in provider),
        ('M02 event control never syncs file worker', 'queue.sync' not in event.split('func start()', 1)[1]),
        ('M02 independent event bridge admission before NSData', 'NECoreEventSink' in bridge and 'eventAdmission' in bridge),
        ('M03 streaming fixed ACK window', 'contentsOfDirectory' not in runner and 'inFlightEventFiles' not in runner and 'deliveryToken' in runner),
        ('M03 notifications coalesce before main hop', 'notificationPending' in runner),
        ('CI01 published immutable baseline', 'd4f707b7ed80d1a9eb2d0de07120bb83f4e228ce' in script),
        ('CI02 sibling replacement initialized', 'core/mihomo core/sing-shadowsocks2' in workflow),
        ('CI03 packaging requires Swift behavior', 'test_ios_swift_review.py --require-swift' in packaging and 'fetch-depth: 0' in packaging and 'needs: [verify, swift-review-native]' in packaging),
    ]
    for label, ok in tests:
        print(('PASS' if ok else 'FAIL') + ' SOURCE ONLY: ' + label)
    return all(ok for _, ok in tests)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-ref')
    args = parser.parse_args()
    raise SystemExit(0 if check_tree(args.source_ref) else 1)
