"""Source/ABI contracts supplement the runtime upgrade tests (never device proof)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Upgrade098Semantics(unittest.TestCase):
    def test_clear_dns_cache_reaches_runtime_and_ios_classification(self):
        for path in ('core/constant.go', 'core/method.go', 'lib/core/method.dart',
                     'lib/core/interface.dart', 'lib/core/controller.dart'):
            self.assertIn('clearDnsCache', (ROOT / path).read_text(encoding='utf-8'), path)
        self.assertIn('resolver.ClearCache()', (ROOT / 'core/dns_query.go').read_text())
        swift = (ROOT / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        self.assertRegex(swift, r'enum RuntimeStateCoreMethod: String \{[^}]*case clearDnsCache')

    def test_android_network_notification_abi_is_complete(self):
        expected = {
            'android/service/src/main/java/cc/chenx/flclash/service/modules/NetworkObserveModule.kt':
                ['Core.updateNetwork(interfaceName, gateway)', 'interfaceName == currentInterfaceName && gateway == currentGateway', 'NetworkCapabilities.TRANSPORT_VPN'],
            'android/core/src/main/java/cc/chenx/flclash/core/Core.kt': ['external fun updateNetwork'],
            'android/core/src/main/cpp/core.cpp': ['Java_cc_chenx_flclash_core_Core_updateNetwork', 'updateNetwork(get_string(interface_name), get_string(gateway))'],
            'core/lib.go': ['//export updateNetwork', 'handleUpdateNetwork'],
            'core/bride_android.go': ['netmon.NotifyNetworkChange', 'C.GoString'],
            'core/bride_ios.go': ['func handleUpdateNetwork'],
            'core/go.mod': ['github.com/YuliZheng/tailscale v0.0.0-20261031162711-834a9a759830', 'replace github.com/metacubex/sing-shadowsocks2 => ./sing-shadowsocks2'],
        }
        for path, tokens in expected.items():
            source = (ROOT / path).read_text(encoding='utf-8')
            for token in tokens:
                self.assertIn(token, source, path)

    def test_windows_installer_restores_only_previously_registered_helper(self):
        source = (ROOT / 'windows/packaging/exe/inno_setup.iss').read_text()
        self.assertRegex(source, r'if RegKeyExists[\s\S]*HelperWasRegistered := True')
        self.assertRegex(source, r'procedure RestoreHelperService;[\s\S]*if HelperWasRegistered then[\s\S]*install')
        self.assertRegex(source, r'if CurStep = ssPostInstall then[\s\S]*RestoreHelperService;[\s\S]*ClearStaleProxy\(True\)')

    def test_new_tests_are_required_not_orphaned(self):
        workflow = (ROOT / '.github/workflows/ios-five-protocol.yaml').read_text()
        for target in ['scripts/test_upgrade098_semantics.py', 'test/upgrade098_semantics_test.dart',
                       'test/release_yf098_literal_test.dart', 'test/views/quick_options_test.dart', 'test/providers/setup_action_test.dart',
                       'scripts/run_ios_error_chain_gate.py', 'scripts/run_android_network_jni_gate.py']:
            self.assertIn(target, workflow)
        self.assertIn('clear-dns-routing', (ROOT / 'scripts/run_ios_error_chain_gate.py').read_text())


if __name__ == '__main__':
    unittest.main()
