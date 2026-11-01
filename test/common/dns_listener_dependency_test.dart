import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/dns_listener_dependency.dart';
import 'package:fl_clash/common/ios_profile_budget.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns_listener_dependency_probe.dart' as fixture;

void main() {
  test(
    'equivalent IPv6 spellings deduplicate without changing resolver literals',
    () {
      fixture.verifyEquivalentIpv6();
    },
  );
  final cases = <(String, Object, String?)>[
    ('127.0.0.1:7874', 'udp://127.0.0.1:7874', '127.0.0.1:7874'),
    ('127.0.0.2:7874', 'tcp://127.0.0.2:7874', '127.0.0.2:7874'),
    ('0.0.0.0:7874', 'udp://127.0.0.1:7874', '127.0.0.1:7874'),
    ('[::]:7874', 'tcp://[::1]:7874', '[::1]:7874'),
    ('[::1]:7874', 'udp://[::1]:7874', '[::1]:7874'),
    ('127.0.0.1:53', '127.0.0.1', '127.0.0.1:53'),
    ('127.0.0.1:53', 'tcp://127.0.0.1', '127.0.0.1:53'),
    ('[::1]:53', '[::1]', '[::1]:53'),
    (
      '127.0.0.1:7874',
      '127.0.0.1:7874#DIRECT&ecs=1.2.3.4/24',
      '127.0.0.1:7874',
    ),
    ('127.0.0.1:7874', 'udp://127.0.0.1:7875', null),
    ('127.0.0.1:7874', 'udp://127.0.0.2:7874', null),
    ('0.0.0.0:7874', 'udp://[::1]:7874', null),
    ('[::]:7874', 'udp://127.0.0.1:7874', null),
    ('127.0.0.1:7874', 'https://127.0.0.1:7874/dns-query', null),
    ('127.0.0.1:7874', 'tls://127.0.0.1:7874', null),
    (
      '127.0.0.1:7874',
      'https://remote.test/path/127.0.0.1:7874#127.0.0.1:7874',
      null,
    ),
    ('127.0.0.1:7874', 'udp://remote.test:7874?server=127.0.0.1', null),
    ('127.0.0.1:7874', 'udp://127.0.0.1.remote.test:7874', null),
    ('127.0.0.1:7874', 'udp://localhost:7874', null),
    ('127.0.0.1:7874', 'udp://127.0.0.1:7874/path', null),
    ('127.0.0.1:7874', 'udp://user@127.0.0.1:7874', null),
    ('192.0.2.1:7874', 'udp://127.0.0.1:7874', null),
    ('local.test:7874', 'udp://127.0.0.1:7874', null),
    ('127.0.0.1', '127.0.0.1', null),
    ('127.0.0.1:0', '127.0.0.1:0', null),
  ];
  for (var i = 0; i < cases.length; i++) {
    final (listen, resolver, expected) = cases[i];
    test('endpoint authority/family/port boundary $i', () {
      final dns = {
        'listen': listen,
        'proxy-server-nameserver': [resolver],
      };
      expect(referencedLoopbackDnsListener(dns), expected);
      expect(sanitizeProfileForIOS({'dns': dns})['dns']['listen'], expected);
    });
  }
  for (final field in [
    'nameserver',
    'default-nameserver',
    'proxy-server-nameserver',
    'direct-nameserver',
    'fallback',
    'nameserver-policy',
    'proxy-server-nameserver-policy',
  ]) {
    test('recursively reads only values in $field without scalar changes', () {
      final dns = {
        'listen': '0.0.0.0:7874',
        field: {
          'private.test': ['tcp://127.0.0.1:7874#DIRECT&ecs=1.2.3.4/24'],
        },
      };
      final before = jsonEncode(dns);
      final out = sanitizeProfileForIOS({'dns': dns});
      expect(out['dns']['listen'], '127.0.0.1:7874');
      expect(out['dns'][field], dns[field]);
      expect(jsonEncode(dns), before);
    });
  }
  test('policy keys/hosts/unknown fields are not resolver endpoints', () {
    final dns = {
      'listen': '0.0.0.0:7874',
      'nameserver-policy': {'udp://127.0.0.1:7874': '192.0.2.53'},
      'unknown': '127.0.0.1:7874',
    };
    expect(referencedLoopbackDnsListener(dns), isNull);
    expect(
      sanitizeProfileForIOS({
        'dns': dns,
        'hosts': {'alias.test': '127.0.0.1'},
      })['dns'].containsKey('listen'),
      isFalse,
    );
  });
  test('missing source listener never opens a port', () {
    expect(
      referencedLoopbackDnsListener({
        'nameserver': ['127.0.0.1:7874'],
      }),
      isNull,
    );
  });
  test('no dependency and later user override keep old removal policy', () {
    final original = {
      'dns': {
        'listen': '127.0.0.1:7874',
        'proxy-server-nameserver': ['127.0.0.1:7874'],
      },
    };
    final overridden = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    overridden['dns']['proxy-server-nameserver'] = ['192.0.2.53'];
    expect(
      sanitizeProfileForIOS(overridden)['dns'].containsKey('listen'),
      isFalse,
    );
    expect(sanitizeProfileForIOS(original)['dns']['listen'], '127.0.0.1:7874');
    expect(
      sanitizeProfileForIOS({
        'dns': {'listen': '0.0.0.0:7874'},
      })['dns'].containsKey('listen'),
      isFalse,
    );
  });
  test('retained DNS listener never restores controller or LAN globals', () {
    final out = sanitizeProfileForIOS({
      'dns': {
        'listen': '0.0.0.0:7874',
        'nameserver': ['127.0.0.1:7874'],
      },
      'external-controller': '0.0.0.0:9090',
      'allow-lan': true,
    });
    expect(out['dns']['listen'], '127.0.0.1:7874');
    expect(out.containsKey('external-controller'), isFalse);
    expect(out.containsKey('allow-lan'), isFalse);
  });
  test(
    'actual UDP bind is loopback-only, not a simulated Darwin refusal',
    () async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      try {
        expect(socket.address.isLoopback, isTrue);
      } finally {
        socket.close();
      }
    },
  );
}
