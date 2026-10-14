import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/common/uri_subscription.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

const privateTemplate = '''
ipv6: false
mixed-port: 7890
proxies: []
proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies: [DIRECT, ⚡ 自动优选]
  - name: ⚡ 自动优选
    type: url-test
    proxies: []
rules: ["MATCH,DIRECT"]
hosts: {template.test: 192.0.2.10}
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver: [1.1.1.1]
  nameserver-policy: {template.test: 1.1.1.1}
  fake-ip-filter: [+.local]
''';
const privateSource = '''
proxies:
  - name: node
    type: ss
    server: example.com
    port: 443
    cipher: aes-128-gcm
    password: synthetic
    unknown-option: untouched
proxy-groups: []
rules: ["MATCH,REJECT"]
hosts:
  secret.test: &addresses [192.0.2.1, '2001:db8::1']
  alias.test: *addresses
  cn.test: '192.0.2.2，2001:db8::2'
dns:
  enable: true
  ipv6: true
  enhanced-mode: redir-host
  fake-ip-range: 198.19.0.1/16
  listen: 127.0.0.1:9999
  use-hosts: true
  use-system-hosts: false
  nameserver: [https://dns.example.test/query?token=synthetic]
  nameserver-policy:
    '+.secret.test': 'https://dns.example.test/query?token=synthetic'
  proxy-server-nameserver-policy:
    secret.test: [192.0.2.53]
  fake-ip-filter: [+.secret.test]
''';
Map<String, dynamic> decode(String text) {
  dynamic plain(dynamic v) => v is Map
      ? {for (final e in v.entries) e.key.toString(): plain(e.value)}
      : v is List
      ? v.map(plain).toList()
      : v;
  return Map<String, dynamic>.from(plain(loadYaml(text)) as Map);
}

Future<Map<String, dynamic>> finalProfile(
  Map<String, dynamic> raw, {
  bool overrideDns = false,
  PatchClashConfig patch = const PatchClashConfig(),
}) async {
  final result = await makeRealProfileTask(
    MakeRealProfileState(
      profilesPath: '/profiles',
      profileId: 42,
      rawConfig: raw,
      realPatchConfig: patch,
      overrideDns: overrideDns,
      appendSystemDns: false,
      proxyGroups: const [],
      rules: const [],
      addedRules: const [],
      defaultUA: 'test',
    ),
  );
  return decode(result.yaml);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'template private DNS and literal hosts survive final isolate task',
    () async {
      final source = decode(privateSource);
      final output = decode(
        applyGlobalProfileTemplate(
          content: privateSource,
          template: privateTemplate,
          enabled: true,
        ),
      );
      final real = await finalProfile(output);
      expect(real['hosts']['secret.test'], source['hosts']['secret.test']);
      expect(real['hosts']['alias.test'], source['hosts']['alias.test']);
      expect(real['hosts']['cn.test'], source['hosts']['cn.test']);
      expect(real['hosts']['template.test'], '192.0.2.10');
      expect(
        real['dns']['nameserver-policy']['+.secret.test'],
        source['dns']['nameserver-policy']['+.secret.test'],
      );
      expect(
        real['dns']['proxy-server-nameserver-policy'],
        source['dns']['proxy-server-nameserver-policy'],
      );
      expect(
        real['dns']['nameserver'],
        containsAll(source['dns']['nameserver'] as List),
      );
      expect(real['dns']['nameserver'], source['dns']['nameserver']);
      expect(real['dns']['use-system-hosts'], false);
      expect(real['dns']['enhanced-mode'], 'fake-ip');
      expect(real['dns']['ipv6'], false);
      expect(real['dns'].containsKey('listen'), false);
      expect(real['rules'], ['MATCH,DIRECT']);
      expect(real['proxies'][0]['unknown-option'], 'untouched');
    },
  );
  test(
    'DNS resolver and selector dependencies are closed without unrelated rules',
    () async {
      final input = decode(privateSource);
      input['rule-providers'] = {
        'private': {
          'type': 'inline',
          'behavior': 'domain',
          'payload': ['+.secret.test'],
        },
        'unused': {
          'type': 'inline',
          'behavior': 'domain',
          'payload': ['+.unused.test'],
        },
      };
      input['proxy-groups'] = [
        {
          'name': 'private-path',
          'type': 'select',
          'proxies': ['node'],
        },
      ];
      input['rules'] = [
        'DOMAIN-SUFFIX,secret.test,private-path',
        'DOMAIN-SUFFIX,unrelated.test,REJECT',
        'MATCH,private-path',
      ];
      input['dns'] = {
        'enable': true,
        'nameserver': ['192.0.2.53#private-path'],
        'nameserver-policy': {
          'rule-set:private': ['192.0.2.54'],
        },
        'fake-ip-filter': ['rule-set:private'],
      };
      final source = yaml.encode(input);
      final output = decode(
        applyGlobalProfileTemplate(
          content: source,
          template: privateTemplate,
          enabled: true,
        ),
      );
      expect(output['rule-providers'].keys, ['private']);
      expect(
        (output['proxy-groups'] as List).any(
          (g) => g['name'] == 'private-path',
        ),
        true,
      );
      expect(
        output['rules'],
        contains('DOMAIN-SUFFIX,secret.test,private-path'),
      );
      expect(output['rules'], contains('MATCH,DIRECT'));
      expect(output['rules'], isNot(contains('MATCH,private-path')));
      expect(
        output['rules'],
        isNot(contains('DOMAIN-SUFFIX,unrelated.test,REJECT')),
      );
      expect(output['dns']['nameserver'], contains('192.0.2.53#private-path'));
    },
  );
  test(
    'fallback filters, private host fake-ip exclusions and source flags preserve template scope',
    () async {
      final input = decode(privateSource);
      input['dns']['fallback-filter'] = {
        'geoip': false,
        'geoip-code': 'ZZ',
        'domain': ['+.secret.test'],
        'ipcidr': ['192.0.2.0/24'],
      };
      input['dns']['use-hosts'] = false;
      final output = decode(
        applyGlobalProfileTemplate(
          content: yaml.encode(input),
          template: '$privateTemplate\n',
          enabled: true,
        ),
      );
      final real = await finalProfile(output);
      expect(real['dns']['fallback-filter']['domain'], ['+.secret.test']);
      expect(real['dns']['fallback-filter']['ipcidr'], ['192.0.2.0/24']);
      expect(
        real['dns']['fake-ip-filter'],
        containsAll([
          'secret.test',
          'alias.test',
          'cn.test',
          '+.secret.test',
          '+.local',
        ]),
      );
      expect(real['dns']['use-hosts'], false);
      expect(real['dns']['use-system-hosts'], false);
    },
  );
  test(
    'explicit user DNS override owns editable fields but keeps uneditable dependencies',
    () async {
      final output = decode(
        applyGlobalProfileTemplate(
          content: privateSource,
          template: privateTemplate,
          enabled: true,
        ),
      );
      final real = await finalProfile(output, overrideDns: true);
      expect(
        real['dns']['nameserver'],
        isNot(contains('https://dns.example.test/query?token=synthetic')),
      );
      expect(
        real['dns']['nameserver-policy'].containsKey('+.secret.test'),
        false,
      );
      expect(
        real['hosts']['secret.test'],
        decode(privateSource)['hosts']['secret.test'],
      );
    },
  );
  test('A to A is idempotent and A to B keeps subscriptions isolated', () {
    final a = applyGlobalProfileTemplate(
      content: privateSource,
      template: privateTemplate,
      enabled: true,
    );
    final aa = applyGlobalProfileTemplate(
      content: a,
      template: privateTemplate,
      enabled: true,
    );
    expect(decode(aa), decode(a));
    final b = applyGlobalProfileTemplate(
      content: privateSource.replaceAll('secret.test', 'other.test'),
      template: privateTemplate,
      enabled: true,
    );
    expect(decode(b)['hosts'].containsKey('secret.test'), false);
    expect(decode(a)['hosts'].containsKey('other.test'), false);
  });
  test(
    'automatic DNS activation preserves raw private policy while explicit override wins',
    () async {
      final raw = decode(privateSource);
      raw['dns']['enable'] = false;
      final real = await finalProfile(raw);
      expect(real['dns']['enable'], false);
      expect(
        real['dns']['nameserver-policy']['+.secret.test'],
        raw['dns']['nameserver-policy']['+.secret.test'],
      );
      expect(
        real['dns']['proxy-server-nameserver-policy'],
        raw['dns']['proxy-server-nameserver-policy'],
      );
      expect(
        real['dns']['nameserver'],
        containsAll(raw['dns']['nameserver'] as List),
      );
    },
  );
  test(
    'final task rejects a script deleting a DNS proxy dependency without logging values',
    () async {
      final raw = decode(privateSource);
      raw['dns']['nameserver'] = ['192.0.2.53#private-path'];
      raw['proxy-groups'] = [
        {
          'name': 'private-path',
          'type': 'select',
          'proxies': ['node'],
        },
      ];
      raw['proxies'] = <dynamic>[];
      await expectLater(
        finalProfile(raw),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('DNS'),
              isNot(contains('192.0.2.53')),
              isNot(contains('private-path')),
            ),
          ),
        ),
      );
    },
  );
  test('YAML aliases and merge maps preserve private host and DNS fields', () {
    const source = '''
proxies: [{name: node, type: ss, password: synthetic}]
rules: ["MATCH,DIRECT"]
hosts:
  <<: &host_defaults {alias.test: '2001:db8::1'}
  secret.test: '192.0.2.1'
dns:
  <<: &dns_defaults
    use-hosts: false
    use-system-hosts: false
    nameserver-policy: {'+.secret.test': [192.0.2.53]}
  enable: true
  nameserver: [1.1.1.1]
''';
    final output = decode(
      applyGlobalProfileTemplate(
        content: source,
        template: privateTemplate,
        enabled: true,
      ),
    );
    expect(output['hosts']['alias.test'], '2001:db8::1');
    expect(output['hosts'].containsKey('<<'), false);
    expect(output['dns']['use-hosts'], false);
    expect(output['dns']['nameserver-policy']['+.secret.test'], ['192.0.2.53']);
  });
  test(
    'literal private DNS and hosts whitespace escapes survive final task',
    () async {
      final input = decode(privateSource);
      input['hosts']['literal.test'] =
          '  alias\\name "quoted"\r\n next\tvalue  ';
      input['dns']['nameserver-policy']['literal.test'] =
          'https://dns.example.test/query?token=synthetic\\quoted';
      final output = decode(
        applyGlobalProfileTemplate(
          content: yaml.encode(input),
          template: privateTemplate,
          enabled: true,
        ),
      );
      final real = await finalProfile(output);
      expect(real['hosts']['literal.test'], input['hosts']['literal.test']);
      expect(
        real['dns']['nameserver-policy']['literal.test'],
        input['dns']['nameserver-policy']['literal.test'],
      );
    },
  );
  test(
    'resolver routing flags override template defaults only when present',
    () {
      final input = decode(privateSource);
      input['dns']['respect-rules'] = false;
      input['dns']['direct-nameserver-follow-policy'] = false;
      final template = decode(privateTemplate);
      template['dns']['respect-rules'] = true;
      template['dns']['direct-nameserver-follow-policy'] = true;
      final output = decode(
        applyGlobalProfileTemplate(
          content: yaml.encode(input),
          template: yaml.encode(template),
          enabled: true,
        ),
      );
      expect(output['dns']['respect-rules'], false);
      expect(output['dns']['direct-nameserver-follow-policy'], false);
      input['dns'].remove('respect-rules');
      final missing = decode(
        applyGlobalProfileTemplate(
          content: yaml.encode(input),
          template: yaml.encode(template),
          enabled: true,
        ),
      );
      expect(missing['dns']['respect-rules'], true);
    },
  );
  test('disabled node-only import retains its previous template path', () {
    final source = decode(privateSource)
      ..remove('rules')
      ..remove('proxy-groups');
    final actual = applyGlobalProfileTemplate(
      content: yaml.encode(source),
      template: privateTemplate,
      enabled: false,
    );
    final expected = injectSubscriptionProxies(
      template: privateTemplate,
      proxies: extractYamlProxies(yaml.encode(source))!,
    );
    expect(decode(actual), decode(expected));
  });
  test(
    'ambiguous whitelist or rule fake-ip mode refuses silent semantic inversion',
    () {
      for (final mode in ['whitelist', 'rule']) {
        final template = decode(privateTemplate);
        template['dns']['fake-ip-filter-mode'] = mode;
        expect(
          () => applyGlobalProfileTemplate(
            content: privateSource,
            template: yaml.encode(template),
            enabled: true,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('fake-ip'),
            ),
          ),
        );
      }
    },
  );
  test(
    'source policy entries precede template broad selectors and win same keys',
    () {
      final template = decode(privateTemplate);
      template['dns']['nameserver-policy'] = {
        'rule-set:broad': ['1.1.1.1'],
        '+.secret.test': ['1.0.0.1'],
      };
      template['rule-providers'] = {
        'broad': {
          'type': 'inline',
          'behavior': 'domain',
          'payload': ['+.test'],
        },
      };
      final output = decode(
        applyGlobalProfileTemplate(
          content: privateSource,
          template: yaml.encode(template),
          enabled: true,
        ),
      );
      expect(output['dns']['nameserver-policy'].keys.first, '+.secret.test');
      expect(
        output['dns']['nameserver-policy']['+.secret.test'],
        decode(privateSource)['dns']['nameserver-policy']['+.secret.test'],
      );
    },
  );
  test('missing DNS reference fails with a non-secret actionable message', () {
    final source = privateSource.replaceFirst(
      'https://dns.example.test/query?token=synthetic',
      'https://dns.example.test/query?token=synthetic#lost-group',
    );
    expect(
      () => applyGlobalProfileTemplate(
        content: source,
        template: privateTemplate,
        enabled: true,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('DNS'),
            isNot(contains('synthetic')),
            isNot(contains('lost-group')),
          ),
        ),
      ),
    );
  });
}
