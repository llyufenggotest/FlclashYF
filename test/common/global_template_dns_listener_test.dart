import 'dart:io';

import 'package:fl_clash/common/ios_profile_budget.dart';
import 'package:fl_clash/common/uri_subscription.dart';
import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns_listener_dependency_probe.dart' as fixture;
import 'global_template_private_dns_test.dart' show finalProfile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final template = File('assets/data/profile_template.yaml').readAsStringSync();
  for (final listen in ['127.0.0.1:7874', '0.0.0.0:7874', '[::]:7874']) {
    test(
      'bundled template -> actual ${Platform.operatingSystem} final task: $listen',
      () async {
        final resolver = listen.startsWith('[')
            ? 'tcp://[::1]:7874#DIRECT&ecs=1.2.3.4/24'
            : 'udp://127.0.0.1:7874#DIRECT&ecs=1.2.3.4/24';
        final source = fixture.source(listen, [resolver]);
        final composed = fixture.decode(
          applyGlobalProfileTemplate(
            content: yaml.encode(source),
            template: template,
            enabled: true,
          ),
        );
        expect(composed['dns']['listen'], listen);
        final real = await finalProfile(composed);
        final local = listen.startsWith('[') ? '[::1]:7874' : '127.0.0.1:7874';
        expect(real['dns']['listen'], Platform.isIOS ? local : listen);
        expect(real['dns']['proxy-server-nameserver'], [resolver]);
        expect(real['hosts']['node.test'], 'alias.test');
        expect(real['proxies'].single['unknown-option'], 'keep');
        expect(real['rules'], composed['rules']);
        expect(real['proxy-groups'], composed['proxy-groups']);
        // Exercise the exact production iOS finalizer after real task generation.
        // This is not an assertion that Windows is a running iOS device.
        final ios = sanitizeProfileForIOS(real);
        expect(ios['dns']['listen'], local);
        expect(ios['dns']['proxy-server-nameserver'], [resolver]);
      },
    );
  }
  test(
    'explicit DNS override remains authoritative through real task and iOS',
    () async {
      final source = fixture.source('127.0.0.1:7874', ['127.0.0.1:7874']);
      final composed = fixture.decode(
        applyGlobalProfileTemplate(
          content: yaml.encode(source),
          template: template,
          enabled: true,
        ),
      );
      final real = await finalProfile(
        composed,
        overrideDns: true,
        patch: const PatchClashConfig(
          dns: Dns(
            listen: '127.0.0.1:9053',
            nameserver: ['192.0.2.53'],
            proxyServerNameserver: [],
            nameserverPolicy: {},
            proxyServerNameserverPolicy: {},
            fallback: [],
          ),
        ),
      );
      expect(real['dns']['nameserver'], ['192.0.2.53']);
      expect(real['dns']['proxy-server-nameserver'], isEmpty);
      expect(sanitizeProfileForIOS(real)['dns'].containsKey('listen'), isFalse);
    },
  );
  test('no listener invention, no subscription cross-contamination', () {
    final a = fixture.source('127.0.0.1:7874', ['127.0.0.1:7874']);
    final b = fixture.source('127.0.0.1:7874', ['192.0.2.53']);
    Map compose(Map input) => fixture.decode(
      applyGlobalProfileTemplate(
        content: yaml.encode(input),
        template: template,
        enabled: true,
      ),
    );
    expect(compose(a)['dns']['listen'], '127.0.0.1:7874');
    expect(compose(b)['dns'].containsKey('listen'), isFalse);
    (a['dns'] as Map).remove('listen');
    expect(compose(a)['dns'].containsKey('listen'), isFalse);
  });
}
