import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:yaml/yaml.dart';

import '../common/global_template_private_dns_test.dart'
    show privateSource, privateTemplate, decode;

Future<Uint8List> _bytes(String s) async => Uint8List.fromList(utf8.encode(s));

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _Core extends Fake implements CoreHandlerInterface {
  String? validated;
  @override
  Future<String> validateConfig(String data) async {
    validated = data;
    return '';
  }

  @override
  Future<List<Map<String, dynamic>>> convertUriSubscription(
    String data,
  ) async => [
    {
      'name': 'node',
      'type': 'ss',
      'server': 'example.com',
      'port': 443,
      'cipher': 'aes-128-gcm',
      'password': 'synthetic',
    },
  ];
}

class _Action extends ProfilesAction {
  String? template;
  @override
  Future<String> loadProfileTemplate() async =>
      template ?? File('assets/data/profile_template.yaml').readAsStringSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'profile-owned source prevents template contamination on rebuild and refresh',
    () async {
      final root = await Directory.systemTemp.createTemp('source_');
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(_Core())),
          profilesActionProvider.overrideWith(_Action.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        PathProviderPlatform.instance = paths;
        await root.delete(recursive: true);
      });
      final action = container.read(profilesActionProvider.notifier) as _Action;
      action.template = privateTemplate;
      final profile = Profile.normal().copyWith(useGlobalTemplate: true);
      await profile.saveFile(
        await _bytes(privateSource),
        prepare: action.prepareProfileConfig,
      );
      final before = await (await profile.file).readAsString();
      action.template = privateTemplate.replaceFirst('1.1.1.1', '9.9.9.9');
      await action.materializeGlobalTemplate(profile);
      final rebuilt = decode(await (await profile.file).readAsString());
      expect(rebuilt['dns']['nameserver'], isNot(contains('1.1.1.1')));
      expect(
        rebuilt['hosts']['secret.test'],
        decode(privateSource)['hosts']['secret.test'],
      );
      await action.materializeGlobalTemplate(profile);
      expect(decode(await (await profile.file).readAsString()), rebuilt);
      final sourceB = privateSource.replaceAll('secret.test', 'other.test');
      await profile.saveFile(
        await _bytes(sourceB),
        prepare: action.prepareProfileConfig,
      );
      final refreshed = decode(await (await profile.file).readAsString());
      expect(refreshed['hosts'].containsKey('secret.test'), false);
      expect(refreshed['hosts'].containsKey('other.test'), true);
      expect(await (await profile.templateSourceFile).readAsString(), sourceB);
      expect(
        action.template,
        privateTemplate.replaceFirst('1.1.1.1', '9.9.9.9'),
      );
      expect(before, isNot(await (await profile.file).readAsString()));
    },
  );
  test(
    'prepare uses the subscription flag and validates generated YAML with Core',
    () async {
      final core = _Core();
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          profilesActionProvider.overrideWith(_Action.new),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(profilesActionProvider.notifier);
      const content =
          'proxies:\n  - name: node\n    type: ss\n    password: synthetic\nrules: ["MATCH,DIRECT"]\n';
      expect(await action.prepareProfileConfig(content, null, false), content);
      final templated = await action.prepareProfileConfig(content, null, true);
      expect(core.validated, templated);
      expect(
        (loadYaml(templated) as YamlMap)['rules'],
        contains('GEOSITE,CN,🎯 全球直连'),
      );
      final uri = await action.prepareProfileConfig(
        'ss://synthetic',
        null,
        false,
      );
      expect(
        (loadYaml(uri) as YamlMap)['rules'],
        contains('GEOSITE,CN,🎯 全球直连'),
      );
    },
  );

  test(
    'materializing rejects proxy providers before changing the file',
    () async {
      final root = await Directory.systemTemp.createTemp('template_provider_');
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = paths;
        await root.delete(recursive: true);
      });
      final core = _Core();
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          profilesActionProvider.overrideWith(_Action.new),
        ],
      );
      addTearDown(container.dispose);
      final profile = Profile.normal().copyWith(useGlobalTemplate: true);
      final file = await profile.file;
      const source = '''
proxy-providers:
  remote:
    type: http
    url: https://example.com/providers.yaml
proxy-groups: []
rules: [MATCH,DIRECT]
''';
      await file.writeAsString(source);
      final action = container.read(profilesActionProvider.notifier);
      await expectLater(
        action.materializeGlobalTemplate(profile),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('proxy-providers'),
          ),
        ),
      );
      expect(await file.readAsString(), source);
    },
  );
}
