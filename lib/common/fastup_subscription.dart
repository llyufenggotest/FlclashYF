import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/yaml.dart';

/// Converts a supported Fastup sing-box JSON subscription to Mihomo YAML.
/// Unsupported input is returned byte-for-byte as text.
String convertFastupSubscription(String content) {
  final text = content.trimLeft();
  if (!text.startsWith('{')) return content;

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return content;
  }
  if (decoded is! Map<String, dynamic>) return content;
  final outbounds = decoded['outbounds'];
  if (outbounds is! List) return content;

  final proxies = <Map<String, Object?>>[];
  for (final outbound in outbounds) {
    if (outbound is! Map || outbound['type'] != 'trojan') continue;
    final mpw = outbound['mpw'];
    final password = outbound['password'];
    final name = outbound['tag'];
    final server = outbound['server'];
    final port = outbound['server_port'];
    if (mpw is! String ||
        mpw.isEmpty ||
        password is! String ||
        password.isEmpty ||
        name is! String ||
        server is! String ||
        port is! num) {
      continue;
    }
    final tlsValue = outbound['tls'];
    final tls = tlsValue is Map ? tlsValue : const <String, Object?>{};
    proxies.add({
      'name': name,
      'type': 'trojan',
      'server': server,
      'port': port.toInt(),
      'password': password.endsWith('#fastup') ? password : '$password#fastup',
      'mpw': mpw,
      if (tls['server_name'] case final String value when value.isNotEmpty)
        'sni': value,
      if (tls['insecure'] is bool) 'skip-cert-verify': tls['insecure'] as bool,
      'udp': true,
    });
  }
  if (proxies.isEmpty) return content;

  final names = proxies.map((proxy) => proxy['name'] as String).toList();
  return yaml.encode({
    'mixed-port': 7890,
    'allow-lan': false,
    'mode': 'rule',
    'log-level': 'info',
    'proxies': proxies,
    'proxy-groups': [
      {'name': 'GLOBAL', 'type': 'select', 'proxies': names},
    ],
    'rules': ['MATCH,GLOBAL'],
  });
}

Uint8List convertFastupSubscriptionBytes(Uint8List bytes) {
  final content = utf8.decode(bytes, allowMalformed: true);
  final converted = convertFastupSubscription(content);
  return identical(converted, content)
      ? bytes
      : Uint8List.fromList(utf8.encode(converted));
}
