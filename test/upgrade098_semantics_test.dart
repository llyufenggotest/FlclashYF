import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    '0.9.8 sniffer override defaults off and retains private template fields',
    () async {
      final raw = <String, dynamic>{
        'sniffer': {
          'enable': false,
          'sniffing': ['tls'],
          'future-private-key': {'keep': true},
          'sniff': {
            'TLS': {
              'ports': ['443'],
            },
          },
        },
        'dns': {'enable': true, 'listen': '127.0.0.1:1053'},
        'proxies': [
          {
            'name': 'private',
            'type': 'Blackstone',
            'password': 'fake',
            'device_id': 'fake-device',
          },
        ],
      };
      for (final enabled in [false, true]) {
        final result = await makeRealProfileTask(
          MakeRealProfileState(
            profilesPath: '/profiles',
            profileId: 98,
            rawConfig: jsonDecode(jsonEncode(raw)),
            realPatchConfig: const PatchClashConfig(
              sniffer: Sniffer(enable: true),
            ),
            overrideDns: false,
            overrideSniffer: enabled,
            appendSystemDns: false,
            proxyGroups: const [],
            rules: const [],
            addedRules: const [],
            defaultUA: 'test',
          ),
        );
        final config = loadYaml(result.yaml) as YamlMap;
        expect(config['sniffer']['enable'], enabled);
        expect(config['sniffer']['future-private-key']['keep'], true);
        expect(config['dns']['listen'], '127.0.0.1:1053');
        expect(config['proxies'][0]['device_id'], 'fake-device');
        if (!enabled) expect(config['sniffer']['sniffing'], ['tls']);
      }
    },
  );

  test('main quick toggles read pre-0.9.8 saved JSON and round-trip', () {
    final oldConfig = AppSettingProps.fromJson({});
    expect(
      oldConfig.dashboardWidgets.contains(DashboardWidget.ipv6Button),
      false,
    );
    for (final ipv6 in [false, true]) {
      final original = PatchClashConfig(
        ipv6: ipv6,
        externalController: '127.0.0.1:9090',
      );
      final restored = PatchClashConfig.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );
      expect(restored.ipv6, ipv6);
      expect(restored.externalController, '127.0.0.1:9090');
    }
  });
}
