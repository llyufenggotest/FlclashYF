import 'package:fl_clash/common/uri_subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const template = '''
proxies: []
proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies: [🎯 全球直连, ⚡ 自动优选]
  - name: ⚡ 自动优选
    type: url-test
    proxies: []
rules: [MATCH,🚀 节点选择]
''';

  test('injects converted proxies into built-in template groups', () {
    final result = injectSubscriptionProxies(
      template: template,
      proxies: [
        {
          'name': 'Pure 1',
          'type': 'vless',
          'uuid': '00112233-4455-6677-8899-aabbccddeeff#pure',
        },
      ],
    );
    final config = loadYaml(result) as YamlMap;
    final groups = config['proxy-groups'] as YamlList;

    expect((config['proxies'] as YamlList).single['uuid'], endsWith('#pure'));
    expect(groups.first['proxies'], ['🎯 全球直连', 'Pure 1', '⚡ 自动优选']);
    expect(groups.last['proxies'], ['Pure 1']);
  });

  test('deduplicates proxy display names without changing protocol fields', () {
    final result = injectSubscriptionProxies(
      template: template,
      proxies: [
        {'name': 'Node', 'type': 'vless', 'uuid': 'a#juzi'},
        {'name': 'Node', 'type': 'vless', 'uuid': 'b#juzi'},
      ],
    );
    final proxies = (loadYaml(result) as YamlMap)['proxies'] as YamlList;

    expect(proxies.map((proxy) => proxy['name']), ['Node', 'Node (2)']);
    expect(proxies.map((proxy) => proxy['uuid']), ['a#juzi', 'b#juzi']);
  });
}
