import 'package:fl_clash/common/uri_subscription.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const template = '''
mode: rule
proxies: []
proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies: [🎯 全球直连, ⚡ 自动优选]
  - name: ⚡ 自动优选
    type: url-test
    proxies: []
rules: [MATCH,🐟 漏网之鱼]
''';

  const fullYaml = '''
mode: global
proxies:
  - name: node
    type: ss
    server: example.com
    port: 443
    cipher: aes-128-gcm
    password: synthetic
proxy-groups:
  - name: custom
    type: select
    proxies: [node]
rules: [MATCH,custom]
''';

  test('global template is disabled by default for new profiles', () {
    expect(Profile.normal().useGlobalTemplate, isFalse);
  });

  test('disabled template preserves a complete YAML profile', () {
    expect(
      applyGlobalProfileTemplate(
        content: fullYaml,
        template: template,
        enabled: false,
      ),
      fullYaml,
    );
  });

  test('enabled template extracts complete YAML nodes', () {
    final result = applyGlobalProfileTemplate(
      content: fullYaml,
      template: template,
      enabled: true,
    );
    final config = loadYaml(result) as YamlMap;
    expect(config['mode'], 'rule');
    expect((config['proxies'] as YamlList).single['name'], 'node');
    expect(config['proxy-groups'], isNot(contains('custom')));
  });

  test('enabled template rejects proxy providers it cannot safely extract', () {
    expect(
      () => applyGlobalProfileTemplate(
        content: '''
proxy-providers:
  remote:
    type: http
    url: https://example.com/proxies.yaml
''',
        template: template,
        enabled: true,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('proxy-providers'),
        ),
      ),
    );
  });

  test('remote overwrite metadata survives template extraction', () {
    final result = applyGlobalProfileTemplate(
      content: '$fullYaml\noverwrite:\n  script: synthetic-script\n',
      template: template,
      enabled: true,
    );
    expect((loadYaml(result) as YamlMap)['overwrite'], {
      'script': 'synthetic-script',
    });
  });

  test('incomplete YAML always uses the template', () {
    final result = applyGlobalProfileTemplate(
      content: 'proxies:\n  - name: node\n    type: ss\n',
      template: template,
      enabled: false,
    );
    final config = loadYaml(result) as YamlMap;
    expect(config['mode'], 'rule');
    expect((config['proxies'] as YamlList).single['name'], 'node');
  });
}
