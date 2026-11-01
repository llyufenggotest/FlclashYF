// Pure Dart production-path probe; no Flutter/native initialization required.
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/dns_listener_dependency.dart';
import 'package:fl_clash/common/ios_profile_budget.dart';
import 'package:fl_clash/common/uri_subscription.dart';
import 'package:fl_clash/common/yaml.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> decode(String text) {
  dynamic plain(dynamic v) => v is Map
      ? {for (final e in v.entries) e.key.toString(): plain(e.value)}
      : v is List
      ? v.map(plain).toList()
      : v;
  return Map<String, dynamic>.from(plain(loadYaml(text)) as Map);
}

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Map<String, dynamic> source(String listen, Object resolver) => {
  'proxies': [
    {
      'name': 'synthetic',
      'type': 'ss',
      'server': 'node.test',
      'port': 443,
      'cipher': 'aes-128-gcm',
      'password': 'synthetic',
      'unknown-option': 'keep',
    },
  ],
  'rules': ['MATCH,REJECT'],
  'hosts': {'node.test': 'alias.test'},
  'dns': {
    'enable': true,
    'listen': listen,
    'nameserver': ['https://dns.example.test/dns-query'],
    'proxy-server-nameserver': resolver,
  },
};

void verifyListenerConflict() {
  final template = decode(
    File('assets/data/profile_template.yaml').readAsStringSync(),
  );
  template['dns']['listen'] = '127.0.0.2:7874';
  template['dns']['nameserver-policy'] = {
    'synthetic-private.test': ['udp://127.0.0.2:7874'],
  };
  final input = source('127.0.0.1:7874', ['udp://127.0.0.1:7874']);
  final snapshot = jsonEncode(input);
  Map<String, dynamic> compose() => decode(
    applyGlobalProfileTemplate(
      content: yaml.encode(input),
      template: yaml.encode(template),
      enabled: true,
    ),
  );
  FormatException? rejection;
  try {
    compose();
  } on FormatException catch (error) {
    rejection = error;
  }
  check(rejection != null, 'conflicting referenced listeners must fail closed');
  check(
    rejection!.message ==
            'DNS listener dependencies conflict. Adapt the template to use one shared local listener.' &&
        rejection.source == null &&
        rejection.offset == null,
    'listener conflict must use a fixed safe error without profile values',
  );
  check(jsonEncode(input) == snapshot, 'conflict mutated source');
  template['dns']['listen'] = '0.0.0.0:7874';
  rejection = null;
  try {
    compose();
  } on FormatException catch (error) {
    rejection = error;
  }
  check(
    rejection != null,
    'referenced wildcard template must not lose its distinct loopback dependency',
  );
  template['dns']['listen'] = '127.0.0.1:7874';
  template['dns']['nameserver-policy'] = {
    'synthetic-private.test': ['udp://127.0.0.1:7874'],
  };
  check(
    compose()['dns']['listen'] == '127.0.0.1:7874',
    'same referenced listener must succeed',
  );
  template['dns']['listen'] = '127.0.0.2:7874';
  template['dns']['nameserver-policy'] = {};
  check(
    compose()['dns']['listen'] == '127.0.0.1:7874',
    'unreferenced template listener must not block source dependency',
  );
  template['dns']['nameserver-policy'] = {
    'synthetic-private.test': ['udp://127.0.0.2:7874'],
  };
  input['dns']['nameserver-policy'] = {
    'synthetic-private.test': ['udp://127.0.0.1:7874'],
  };
  check(
    compose()['dns']['listen'] == '127.0.0.1:7874',
    'overwritten template policy must not count as a surviving dependency',
  );
  print('PASS fixed safe listener conflict rejection and compatible controls');
}

void verifyEquivalentIpv6() {
  final template = File('assets/data/profile_template.yaml').readAsStringSync();
  for (final resolvers in [
    ['tcp://[::1]:7874', 'tcp://[0:0:0:0:0:0:0:1]:7874'],
    ['tcp://[0:0:0:0:0:0:0:1]:7874', 'tcp://[::1]:7874'],
  ]) {
    final input = source('[::]:7874', resolvers);
    final snapshot = jsonEncode(input);
    final listener = referencedLoopbackDnsListener(input['dns'] as Map);
    check(
      listener != null,
      'equivalent IPv6 endpoints must deduplicate by address',
    );
    final composed = decode(
      applyGlobalProfileTemplate(
        content: yaml.encode(input),
        template: template,
        enabled: true,
      ),
    );
    final ios = sanitizeProfileForIOS(composed);
    check(
      composed['dns']['listen'] == '[::]:7874' &&
          ios['dns']['listen'] == listener,
      'IPv6 template and finalizer must retain the equivalent loopback listener',
    );
    check(
      jsonEncode(ios['dns']['proxy-server-nameserver']) ==
          jsonEncode(resolvers),
      'IPv6 raw resolver literals must remain unchanged',
    );
    check(jsonEncode(input) == snapshot, 'IPv6 source mutated');
  }
  check(
    referencedLoopbackDnsListener({
          'listen': '0.0.0.0:7874',
          'nameserver': ['127.0.0.1:7874', '127.0.0.2:7874'],
        }) ==
        null,
    'genuinely distinct loopbacks must still reject narrowing',
  );
  print(
    'PASS equivalent IPv6 address deduplication with raw literals preserved',
  );
}

Future<void> main() async {
  verifyListenerConflict();
  verifyEquivalentIpv6();
  final template = File('assets/data/profile_template.yaml').readAsStringSync();
  final input = source('127.0.0.1:7874', ['udp://127.0.0.1:7874']);
  final snapshot = jsonEncode(input);
  final composed = decode(
    applyGlobalProfileTemplate(
      content: yaml.encode(input),
      template: template,
      enabled: true,
    ),
  );
  check(
    composed['dns']['listen'] == '127.0.0.1:7874',
    'global template lost referenced source listener',
  );
  final ios = sanitizeProfileForIOS(composed);
  check(
    ios['dns']['listen'] == '127.0.0.1:7874',
    'iOS sanitizer lost referenced listener',
  );
  check(jsonEncode(input) == snapshot, 'source mutated');
  check(
    jsonEncode(ios['dns']['proxy-server-nameserver']) ==
        jsonEncode(input['dns']['proxy-server-nameserver']),
    'resolver changed',
  );
  final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final client = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final replies = client.asBroadcastStream();
  final serverEvents = server.listen((event) {
    if (event != RawSocketEvent.read) return;
    final packet = server.receive();
    if (packet != null) server.send(packet.data, packet.address, packet.port);
  });
  try {
    final port = server.port;
    final live = source('0.0.0.0:$port', ['udp://127.0.0.1:$port']);
    final finalConfig = sanitizeProfileForIOS(
      decode(
        applyGlobalProfileTemplate(
          content: yaml.encode(live),
          template: template,
          enabled: true,
        ),
      ),
    );
    check(
      finalConfig['dns']['listen'] == '127.0.0.1:$port',
      'live probe final listener not loopback',
    );
    // A synthetic DNS query traverses an actual UDP loopback socket. This is
    // transport evidence, not a claim to run the embedded core or reproduce
    // Darwin ECONNREFUSED on Windows.
    final response = replies.firstWhere((e) => e == RawSocketEvent.read);
    final query = <int>[
      0x12,
      0x34,
      1,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      97,
      4,
      116,
      101,
      115,
      116,
      0,
      0,
      1,
      0,
      1,
    ];
    client.send(query, InternetAddress.loopbackIPv4, port);
    await response.timeout(const Duration(seconds: 3));
    check(
      jsonEncode(client.receive()?.data) == jsonEncode(query),
      'loopback UDP transport mismatch',
    );
    print('PASS actual loopback UDP transport and synthesized local bind');
  } finally {
    await serverEvents.cancel();
    client.close();
    server.close();
  }
  print(
    'PASS bundled template -> iOS referenced listener; literal resolver preserved',
  );
}
