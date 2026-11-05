"""Source contract and immutable-original fallback proof; not native acceptance."""
import hashlib
from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
BASE = 'a64057ef534c00ca1c22d9e646018ba1c90f96dd'
def body(text, marker):
    start = text.index(marker)
    begin = text.index('{', start)
    depth = 1
    end = begin + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
class Contract(unittest.TestCase):
    def test_provider_original_tail(self):
        path = 'ios/NECore/PacketTunnelProvider.swift'
        old = subprocess.check_output(['git','-C',str(ROOT),'show',f'{BASE}:{path}']).decode().replace('\r\n','\n')
        new = (ROOT/path).read_text()
        prefix = '    if OfficialIPCWire.intercept(messageData, completion: completionHandler) { return }\n'
        self.assertIn(prefix, new)
        self.assertEqual(body(old,'override func handleAppMessage('), body(new,'override func handleAppMessage(').replace(prefix,''))
    def test_public_transport_only(self):
        text = (ROOT/'ios/Runner/OfficialIPCProbe.swift').read_text()
        self.assertIn('session.sendProviderMessage(request)', text)
        for token in ['ProviderMessageBridge','startVPNTunnel','stopVPNTunnel','saveToPreferences','localizedDescription','containerURL']:
            self.assertNotIn(token, text)
        for token in ['8','profile_unavailable','timeout','nil_response','mismatch','generation','nonce_equal','UserDefaults.standard','status_before','status_after']:
            self.assertIn(token,text)
    def test_explicit_export_and_ci(self):
        channel = (ROOT/'ios/Runner/ServiceChannel.swift').read_text()
        self.assertIn('case "testOfficialProviderIPC":',channel)
        self.assertIn('OfficialIPCProbe.export()',channel)
        workflow = (ROOT/'.github/workflows/ios-five-protocol.yaml').read_text()
        job = workflow.split('  startup-diagnostics-native:',1)[1].split('  ios:',1)[0]
        self.assertIn('test_ios_official_ipc_swift.py',job)
        self.assertIn('${{ runner.temp }}/official-ipc',job)
        self.assertIn('if: always()',job)
        dart = (ROOT/'lib/views/logs.dart').read_text()
        self.assertIn('testOfficialProviderIPC',dart)
        self.assertIn('showMessage',dart)
    def test_native_slice_manifest(self):
        import tempfile
        import test_ios_official_ipc_swift as gate
        import json
        with tempfile.TemporaryDirectory() as temporary:
            for baseline in [True, False]:
                folder, files = gate.prepare(Path(temporary), baseline)
                manifest = json.loads((folder/'sources.json').read_text())
                provider = next(row for row in manifest if row['path'].endswith('PacketTunnelProvider.swift'))
                self.assertEqual(provider['ref'], BASE if baseline else 'candidate')
                source = (folder/'dependencies.swift').read_text()
                self.assertEqual('OfficialIPCWire.intercept(messageData' in source, not baseline)
                for row in manifest:
                    self.assertEqual(row['compiled_sha256'], hashlib.sha256((folder/row['compiled_file']).read_bytes()).hexdigest())
                self.assertEqual(len(files), 4)

    def test_shared_target_membership(self):
        project = (ROOT/'ios/Runner.xcodeproj/project.pbxproj').read_text()
        self.assertGreaterEqual(project.count('StartupEnvelope.swift in Runner Sources'),2)
        self.assertGreaterEqual(project.count('StartupEnvelope.swift in NECore Sources'),2)
        self.assertGreaterEqual(project.count('OfficialIPCProbe.swift in Sources'),2)
if __name__ == '__main__': unittest.main()
