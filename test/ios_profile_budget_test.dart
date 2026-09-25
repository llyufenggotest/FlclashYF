import 'package:fl_clash/common/ios_profile_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> desktopProfile() => {
    'port': 7891,
    'socks-port': 7892,
    'redir-port': 7893,
    'tproxy-port': 7895,
    'mixed-port': 7890,
    'allow-lan': true,
    'bind-address': '*',
    'external-controller': '127.0.0.1:9090',
    'secret': 'super-secret',
    'find-process-mode': 'always',
    'tcp-concurrent': true,
    'keep-alive-interval': 15,
    'dns': {'enable': true, 'listen': '0.0.0.0:12053', 'ipv6': false},
    'sniffer': {'enable': true},
    'unified-delay': true,
    'proxies': [
      {'name': 'a', 'type': 'oppa', 'pre-connect': 8},
      {'name': 'b', 'type': 'oppa', 'pre-connect': 3},
      {'name': 'c', 'type': 'vless'},
    ],
    'proxy-groups': [
      {
        'name': 'auto',
        'type': 'url-test',
        'interval': 60,
        'proxies': ['a', 'b'],
      },
      {
        'name': 'pick',
        'type': 'select',
        'proxies': ['auto'],
      },
      {
        'name': 'fb',
        'type': 'fallback',
        'interval': 30,
        'proxies': ['a'],
      },
    ],
    'rule-providers': {
      'cn': {'type': 'http', 'interval': 86400, 'url': 'https://x/cn.txt'},
      'inline': {
        'type': 'inline',
        'payload': ['DOMAIN,a.com'],
      },
    },
  };

  group('inbound and control-plane keys', () {
    test('drops listener ports the extension must never open', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      for (final key in [
        'port',
        'socks-port',
        'redir-port',
        'tproxy-port',
        'allow-lan',
        'bind-address',
      ]) {
        expect(out.containsKey(key), isFalse, reason: '$key must be removed');
      }
    });

    test('keeps mixed-port because NEProxySettings and checkIp dial it', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      expect(out['mixed-port'], 7890);
    });

    test('drops the external controller and its secret', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      expect(out.containsKey('external-controller'), isFalse);
      expect(out.containsKey('secret'), isFalse);
    });

    test('drops the profile DNS listener owned by the tunnel process', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      final dns = out['dns'] as Map;
      expect(dns.containsKey('listen'), isFalse);
      expect(dns['enable'], isTrue, reason: 'DNS itself must stay enabled');
    });
  });

  group('mobile-appropriate defaults', () {
    test('disables process matching that iOS cannot perform', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      expect(out['find-process-mode'], 'off');
    });

    test('disables tcp-concurrent and relaxes keep-alive', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      expect(out['tcp-concurrent'], isFalse);
      expect(out['keep-alive-interval'], 30);
    });

    test('keeps sniffer and unified-delay untouched', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      expect((out['sniffer'] as Map)['enable'], isTrue);
      expect(out['unified-delay'], isTrue);
    });
  });

  group('memory budget', () {
    test('caps oppa pre-connect without touching lower values', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      final proxies = out['proxies'] as List;
      expect(proxies[0]['pre-connect'], 2);
      expect(proxies[1]['pre-connect'], 2);
      expect(proxies[2].containsKey('pre-connect'), isFalse);
    });

    test('raises health-check intervals on latency-test groups only', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      final groups = out['proxy-groups'] as List;
      expect(groups[0]['interval'], 300);
      expect(groups[1].containsKey('interval'), isFalse);
      expect(groups[2]['interval'], 300);
    });

    test('raises remote rule-provider intervals, ignores inline ones', () {
      final out = sanitizeProfileForIOS(desktopProfile());
      final providers = out['rule-providers'] as Map;
      expect(providers['cn']['interval'], 604800);
      expect(providers['inline'].containsKey('interval'), isFalse);
    });
  });

  group('safety', () {
    test('never mutates the caller\'s map or nested structures', () {
      final input = desktopProfile();
      sanitizeProfileForIOS(input);
      expect(input['port'], 7891);
      expect((input['dns'] as Map)['listen'], '0.0.0.0:12053');
      expect((input['proxies'] as List)[0]['pre-connect'], 8);
    });

    test('tolerates a profile with none of the affected keys', () {
      final out = sanitizeProfileForIOS({'proxies': [], 'rules': []});
      expect(out['find-process-mode'], 'off');
      expect(out['proxies'], isEmpty);
    });

    test('leaves protocol fields of custom outbounds alone', () {
      final out = sanitizeProfileForIOS({
        'proxies': [
          {
            'name': 'x',
            'type': 'vless',
            'network': 'xhttp',
            'xhttp-opts': {'mode': 'BLACKSTONE'},
            'servername': 'a.com',
          },
        ],
      });
      final proxy = (out['proxies'] as List).first as Map;
      expect(proxy['network'], 'xhttp');
      expect((proxy['xhttp-opts'] as Map)['mode'], 'BLACKSTONE');
      expect(proxy['servername'], 'a.com');
    });
  });
}
