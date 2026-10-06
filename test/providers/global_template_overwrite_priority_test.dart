import 'dart:io';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:yaml/yaml.dart';

import '../helpers/test_profiles.dart';
import '../plugins/code_forge/support.dart';

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
  @override
  Future<Map<String, dynamic>> getProfileConfig(int id) async => {
    'proxies': [
      {
        'name': 'node',
        'type': 'ss',
        'server': 'example.com',
        'port': 443,
        'cipher': 'aes-128-gcm',
        'password': 'synthetic',
      },
    ],
    'proxy-providers': <String, dynamic>{},
    'proxy-groups': [
      {
        'name': '🚀 节点选择',
        'type': 'select',
        'proxies': ['node', '⚡ 自动优选'],
      },
      {
        'name': '⚡ 自动优选',
        'type': 'url-test',
        'proxies': ['node'],
      },
    ],
    'rule': ['GEOSITE,CN,🎯 全球直连', 'MATCH,🐟 漏网之鱼'],
  };
}

class _Action extends ProfilesAction {
  @override
  Future<String> loadProfileTemplate() =>
      File('assets/data/profile_template.yaml').readAsString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    globalState.packageInfo = PackageInfo(
      appName: 'FlClash',
      packageName: 'test',
      version: '1',
      buildNumber: '1',
    );
    await initEditorNative();
  });
  for (final type in [OverwriteType.standard, OverwriteType.script]) {
    test(
      'local ${type.name} overwrite takes priority after global template',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'template_priority_',
        );
        final paths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        final profile = Profile.normal().copyWith(
          useGlobalTemplate: true,
          overwriteType: type,
        );
        final script = await Script.create(label: 'Local').save('''
function main(config) {
  if (!config.rules.includes('GEOSITE,CN,🎯 全球直连')) throw new Error('template missing');
  config.rules = ['DOMAIN,local.example,REJECT', ...config.rules];
  return config;
}
''');
        final container = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            coreHandlerProvider.overrideWithValue(
              CoreController.scoped(_Core()),
            ),
            profilesActionProvider.overrideWith(_Action.new),
          ],
        );
        globalState.container = container;

        addTearDown(() async {
          container.dispose();
          PathProviderPlatform.instance = paths;
          await root.delete(recursive: true);
        });
        final result = await container
            .read(setupActionProvider.notifier)
            .getProfile(
              setupState: SetupState(
                profileId: profile.id,
                profileLastUpdateDate: null,
                overwriteType: type,
                rules: [],
                proxyGroups: [],
                addedRules: [Rule.parse('DOMAIN,local.example,REJECT')],
                script: type == OverwriteType.script ? script : null,
                overrideDns: false,
                dns: const Dns(),
              ),
              patchConfig: const PatchClashConfig(),
            );
        final config = loadYaml(result.yaml) as YamlMap;
        expect(
          (config['rules'] as YamlList).first,
          'DOMAIN,local.example,REJECT',
        );
        expect((config['proxies'] as YamlList).single['name'], 'node');
        expect(config.containsKey('overwrite'), isFalse);
      },
    );
  }
}
