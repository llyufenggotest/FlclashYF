import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('built-in template uses only the requested groups and rules', () {
    final config =
        loadYaml(File('assets/data/profile_template.yaml').readAsStringSync())
            as YamlMap;
    expect((config['proxy-groups'] as YamlList).map((group) => group['name']), [
      '🚀 节点选择',
      '🎯 全球直连',
      '🐟 漏网之鱼',
      '⚡ 自动优选',
    ]);
    expect(config['rules'], [
      'DST-PORT,123,🎯 全球直连',
      'RULE-SET,BanAD,REJECT',
      'GEOIP,CN,🎯 全球直连',
      'GEOSITE,CN,🎯 全球直连',
      'MATCH,🐟 漏网之鱼',
    ]);
    expect((config['rule-providers'] as YamlMap).keys, ['BanAD']);
    expect(config['rule-providers']['BanAD'], {
      'type': 'http',
      'behavior': 'domain',
      'interval': 604800,
      'path': 'BanAD.yaml',
      'url':
          'https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main//Filters/AWAvenue-Ads-Rule-Clash.yaml',
    });
    expect(config['find-process-mode'], 'off');
    expect(config['proxies'], isEmpty);
  });
}
