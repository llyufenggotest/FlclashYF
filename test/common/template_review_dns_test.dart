import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/common/uri_subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'global_template_private_dns_test.dart' show finalProfile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> config() => {
    'proxies': <dynamic>[],
    'proxy-groups': [
      {
        'name': 'Group One',
        'type': 'select',
        'proxies': ['DIRECT'],
      },
    ],
    'dns': {
      'enable': true,
      'enhanced-mode': 'redir-host',
      'fake-ip-filter-mode': 'whitelist',
      'nameserver': ['1.1.1.1'],
    },
  };
  test('T3 inactive fake-ip whitelist accepts source hosts', () {
    final c = config();
    mergeSubscriptionDns(c, {
      'hosts': {'private.test': '192.0.2.1'},
    });
    expect(c['dns']['fake-ip-filter-mode'], 'whitelist');
    expect(c['hosts']['private.test'], '192.0.2.1');
  });
  test(
    'T4 decoded last fragment token matches Core without rewriting URL',
    () async {
      for (final url in [
        'https://dns.test/dns-query#Group%20One',
        'https://dns.test/dns-query#DIRECT&proxy=socks5&Group%20One&doh=h3',
        'https://dns.test/dns-query#Group One',
        'https://dns.test/dns-query#Missing&',
      ]) {
        final c = config();
        c['dns']['nameserver'] = [url];
        validateProfileDnsDependencies(c);
        final finalConfig = await finalProfile(c);
        expect(finalConfig['dns']['nameserver'], [url]);
      }
    },
  );
  test(
    'T5 resolver pools preserve source declarations instead of racing defaults',
    () {
      final c = config();
      c['dns']['fallback'] = ['9.9.9.9'];
      c['dns']['proxy-server-nameserver'] = ['8.8.8.8'];
      c['dns']['direct-nameserver'] = ['8.8.4.4'];
      c['dns']['default-nameserver'] = ['1.0.0.1'];
      final source = {
        'dns': {
          'nameserver': ['192.0.2.53'],
          'fallback': ['192.0.2.54'],
          'proxy-server-nameserver': ['192.0.2.55'],
          'direct-nameserver': ['192.0.2.56'],
          'default-nameserver': ['192.0.2.57'],
          'enable': false,
          'fallback-filter': {'geoip': false, 'geoip-code': 'ZZ'},
        },
      };
      mergeSubscriptionDns(c, source);
      for (final key in (source['dns'] as Map).keys) {
        expect(
          c['dns'][key],
          (source['dns'] as Map)[key],
          reason: key.toString(),
        );
      }
    },
  );
  test(
    'T4 explicit ordinary DNS override accepts encoded legal group',
    () async {
      final c = config();
      const url = 'https://dns.test/dns-query#Group%20One';
      const patch = PatchClashConfig(dns: Dns(nameserver: [url]));
      final result = await finalProfile(c, overrideDns: true, patch: patch);
      expect(result['dns']['nameserver'], [url]);
    },
  );
  test(
    'T5 source disabled DNS stays disabled through final generation',
    () async {
      final c = config();
      c['dns']['enable'] = false;
      final result = await finalProfile(c);
      expect(result['dns']['enable'], false);
    },
  );
}
