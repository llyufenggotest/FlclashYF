"""Portable source contract only; NOT Swift/native behavior acceptance."""
from pathlib import Path
import argparse
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='a3aa75b3b7c851caa80d9d6964158d7e5ffbb478'
def main():
    p=argparse.ArgumentParser();p.add_argument('--baseline',action='store_true');p.add_argument('--baseline-ref',default=BASE);a=p.parse_args()
    def source(rel):
        return subprocess.check_output(['git','-C',str(ROOT),'show',f'{a.baseline_ref}:{rel}']).decode() if a.baseline else (ROOT/rel).read_text()
    c=source('ios/Runner/Tunnel/TunnelCoordinator.swift')
    r=source('ios/Runner/Core/CoreMessageRouter.swift')
    t=source('ios/Runner/Tunnel/TunnelController.swift')
    checks=[('real-start-awaits-dns', 'let dnsReleased = await changeAppDNSOwnership(suspended: true)' in c and c.index('let dnsReleased = await changeAppDNSOwnership(suspended: true)') < c.index('try manager.connection.startVPNTunnel()')),
      ('post-await-current-owner', 'guard isCurrent(request) else { return }\n      guard dnsReleased else' in c),
      ('serialized-dns-operations', 'await previous.value' in c),
      ('configuration-preflight', 'await tunnelController.prepareAppDNSForConfiguration()' in r),
      ('strict-actual-bool', 'CFGetTypeID(result) == CFBooleanGetTypeID()' in r),
      ('no-envelope-error', 'payload["error"] == nil || payload["error"] is NSNull' in r),
      ('connecting-protection', 'status.isLifecycleActive' in c),
      ('controller-wiring', 'setAppDNSSuspended: { await CoreMessageRouter.setAppDNSListenerSuspended($0) }' in t),
      ('idle-await-rechecks-configuration', '!configurationContinuations.isEmpty' in c.split('let ownershipRevision = dnsOwnershipRevision')[-1].split('isCoordinatorRunning = false')[0]),
      ('original-timeout', 'private let connectTimeout: TimeInterval = 5' in c)]
    for name,ok in checks:print(('PASS' if ok else 'FAIL')+' PORTABLE-SOURCE '+name)
    return 0 if all(ok for _,ok in checks) else 1
if __name__=='__main__':raise SystemExit(main())
