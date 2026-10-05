import 'package:fl_clash/common/protocol_edit_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Oppa keeps the standard editor and XHTTP/BLACKSTONE are read-only', () {
    expect(
      protocolEditPolicyForYaml('proxies:\n  - {name: o, type: oppa}'),
      ProtocolEditPolicy.standard,
    );
    expect(
      protocolEditPolicyForYaml(
        'proxies:\n  - {name: x, type: vless, network: xhttp}',
      ),
      ProtocolEditPolicy.readOnly,
    );
    expect(
      protocolEditPolicyForYaml(
        'proxies:\n  - {name: b, type: trojan, password: token#BLACKSTONE}',
      ),
      ProtocolEditPolicy.readOnly,
    );
  });

  test('standard protocols keep the existing editor', () {
    for (final type in ['ss', 'vmess', 'trojan', 'vless']) {
      expect(
        protocolEditPolicyForYaml(
          'proxies:\n  - {name: standard, type: $type}',
        ),
        ProtocolEditPolicy.standard,
      );
    }
  });
}
