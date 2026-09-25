import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/fastup_subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('converts valid Fastup JSON to Mihomo YAML', () {
    final source = jsonEncode({
      'outbounds': [
        {
          'type': 'trojan',
          'tag': 'Fastup fixture',
          'server': 'node.example',
          'server_port': 443,
          'password': 'synthetic-password',
          'mpw': 'rotated-mpw',
          'tls': {'server_name': 'www.example.com', 'insecure': true},
        },
      ],
    });
    final converted = convertFastupSubscription(source);
    final document = loadYaml(converted) as YamlMap;
    final proxy = (document['proxies'] as YamlList).single as YamlMap;
    expect(proxy['password'], 'synthetic-password#fastup');
    expect(proxy['mpw'], 'rotated-mpw');
    expect(proxy['sni'], 'www.example.com');
  });

  test('leaves unsupported inputs unchanged', () {
    for (final source in [
      'proxies:\n  - name: Standard\n    type: trojan\n',
      '{not json',
      jsonEncode({
        'outbounds': [
          {'type': 'vmess'},
        ],
      }),
      jsonEncode({
        'outbounds': [
          {'type': 'trojan', 'password': 'x'},
        ],
      }),
    ]) {
      expect(convertFastupSubscription(source), source);
      final bytes = Uint8List.fromList(utf8.encode(source));
      expect(convertFastupSubscriptionBytes(bytes), same(bytes));
    }
  });
}
