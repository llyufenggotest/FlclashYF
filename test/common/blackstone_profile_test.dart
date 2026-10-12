import 'dart:convert';

import 'package:fl_clash/common/proxy_type_label.dart';
import 'package:fl_clash/common/protocol_edit_policy.dart';
import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/features/editor/clash_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'Blackstone labels canonical and legacy types without rewriting input',
    () {
      for (final type in ['Blackstone', 'blackstone', 'xhttp', 'XHttp']) {
        expect(proxyTypeLabel(type), 'Blackstone');
      }
      for (final type in ['VLESS', 'Selector', 'unknown']) {
        expect(proxyTypeLabel(type), type);
      }
    },
  );

  test('device escaping handles sentinel collisions and scalar-like names', () {
    for (final name in [
      '',
      'true',
      '001',
      'null',
      ' 平板 ',
      'a: b # c',
      'FLCLASH_DEVICE_SCALAR_0_END',
      'a\r\nb\t\\"',
    ]) {
      final original = {'device_name': name, 'device_id': 'fake-id'};
      expect(loadYaml(yaml.encode(original)), original);
    }
  });

  test('mixed profiles retain the standard transport edit guard', () {
    expect(
      protocolEditPolicyForYaml('''
proxies:
  - {name: private, type: Blackstone, password: fake-token}
  - {name: standard, type: vless, network: xhttp}
'''),
      ProtocolEditPolicy.readOnly,
    );
  });

  for (final type in ['Blackstone', 'xhttp']) {
    test('$type offers literal device fields in the editor', () {
      final schema = EditorSchema.proxy.root;
      expect(schema.fields['type']!.values, contains(type));
      final fields = schema.fieldsFor(type);
      for (final key in ['password', 'node-id', 'device_id', 'device_name']) {
        expect(fields[key]?.kind, YamlKind.scalar, reason: key);
      }
      expect(fields, isNot(contains('device-id')));
      expect(fields, isNot(contains('device-name')));
    });

    test('$type permits editing device context', () {
      expect(
        protocolEditPolicyForYaml(
          'proxies:\n  - {name: synthetic, type: $type, password: fake-token}',
        ),
        ProtocolEditPolicy.standard,
      );
    });

    test('$type import/copy/share/save preserves synthetic context', () {
      final original = <String, dynamic>{
        'proxies': [
          {
            'name': 'synthetic',
            'type': type,
            'server': 'example.invalid',
            'port': 443,
            'password': 'fake-token',
            'node-id': 7,
            'device_id': 'fake-device-001',
            'device_name': ' 测试 平板 "quoted" \\ path\n第二行 ',
            'future_option': {'keep': true},
          },
        ],
      };
      final imported = loadYaml(yaml.encode(original));
      final copied = jsonDecode(jsonEncode(imported));
      final shared = utf8.encode(yaml.encode(copied));
      final saved = loadYaml(utf8.decode(shared));
      expect(saved, original);
      final proxy = saved['proxies'][0];
      expect(proxy.containsKey('device_id'), isTrue);
      expect(proxy.containsKey('device_name'), isTrue);
      expect(proxy.containsKey('device-id'), isFalse);
    });
  }

  test('standard VLESS XHTTP transport and x365 remain unchanged', () {
    final fields = EditorSchema.proxy.root.fieldsFor('vless');
    expect(fields['network']!.values, contains('xhttp'));
    expect(fields['xhttp-opts']!.fields, contains('path'));
    expect(fields, isNot(contains('device_id')));
    expect(
      protocolEditPolicyForYaml(
        'proxies:\n  - {name: standard, type: vless, network: xhttp, uuid: fake#x365}',
      ),
      ProtocolEditPolicy.readOnly,
    );
  });

  test('absent optional device context is not invented on save', () {
    final source = {
      'proxies': [
        {'name': 'synthetic', 'type': 'Blackstone', 'password': 'fake-token'},
      ],
    };
    expect(loadYaml(yaml.encode(source)), source);
  });
}
