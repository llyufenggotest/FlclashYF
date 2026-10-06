import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:yaml/yaml.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

class _Core extends Fake implements CoreHandlerInterface {
  @override
  Future<String> validateConfig(String content) async => '';
  @override
  Future<List<Map<String, dynamic>>> convertUriSubscription(
    String content,
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
  @override
  Future<String> loadProfileTemplate() async =>
      File('assets/data/profile_template.yaml').readAsString();
}

base class _File extends PlatformFile {
  _File(this.path);
  @override
  final String path;
  @override
  String get name => 'picked.yaml';
  @override
  Uri get uri => File(path).uri;
  @override
  XFile get xFile => XFile(path);
  @override
  Future<int> length() => File(path).length();
  @override
  int lengthSync() => File(path).lengthSync();
  @override
  Future<Uint8List> readAsBytes() => File(path).readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      File(path).openRead().map(Uint8List.fromList);
}

class _Picker extends FilePickerPlatform {
  _Picker(this.file);
  final PlatformFile file;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => file;
}

class _Images extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile('synthetic.png');
}

class _Scanner extends MobileScannerPlatform {
  _Scanner(this.url);
  final String url;
  @override
  Future<BarcodeCapture?> analyzeImage(
    String path, {
    List<BarcodeFormat> formats = const [],
  }) async => BarcodeCapture(barcodes: [Barcode(rawValue: url)]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'import actions persist their own template choice without changing existing profiles',
    () async {
      await AppLocalizations.load(const Locale('en'));
      globalState.packageInfo = PackageInfo(
        appName: 'FlClash',
        packageName: 'test',
        version: '1',
        buildNumber: '1',
      );
      final root = await Directory.systemTemp.createTemp('import_template_');
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final database = db.Database(NativeDatabase.memory());
      final oldDatabase = db.database;
      db.database = database;
      final existing = Profile.normal(
        label: 'Existing',
        url: 'https://example.com/existing',
      );
      await database.profilesDao.putAll([existing.toCompanion()]);
      final container = ProviderContainer(
        overrides: [
          profilesStreamProvider.overrideWith((_) => Stream.value([existing])),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(_Core())),
          profilesActionProvider.overrideWith(_Action.new),
        ],
      );
      globalState.container = container;
      container.listen(profilesStreamProvider, (_, _) {});
      await container.read(profilesStreamProvider.future);
      final action = container.read(profilesActionProvider.notifier);
      const yaml =
          'proxies: [{name: node, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: synthetic}]\nproxy-groups: []\nrules: ["MATCH,DIRECT"]\n';
      final source = File('${root.path}/picked.yaml');
      await source.writeAsString(yaml);
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _Picker(_File(source.path));
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.write(yaml);
        await request.response.close();
      });
      addTearDown(() async {
        container.dispose();
        db.database = oldDatabase;
        await database.close();
        PathProviderPlatform.instance = paths;
        FilePickerPlatform.instance = originalPicker;
        HttpOverrides.global = overrides;
        await server.close(force: true);
        await root.delete(recursive: true);
      });

      Future<Profile> imported(String label, bool flag) async {
        final rows = await database.profilesDao.query().get();
        final profile = rows.singleWhere((p) => p.label == label);
        expect(profile.useGlobalTemplate, flag);
        final saved =
            loadYaml(await (await profile.file).readAsString()) as YamlMap;
        expect(
          saved['rules'],
          flag ? contains('GEOSITE,CN,🎯 全球直连') : ['MATCH,DIRECT'],
        );
        expect(rows.singleWhere((p) => p.id == existing.id), existing);
        return profile;
      }

      await action.addProfileFromClipboardContent(yaml, 'Off');
      await imported('Off', false);
      await action.addProfileFromClipboardContent(yaml, 'On', true);
      await imported('On', true);
      await action.addProfileFormFile(useGlobalTemplate: true);
      await imported('picked.yaml', true);
      final url = 'http://127.0.0.1:${server.port}/profile.yaml';
      await action.addProfileFormURL(
        url,
        label: 'URL',
        useGlobalTemplate: true,
      );
      await imported('URL', true);
      await action.addProfileFromClipboardContent(url, 'Clipboard URL', true);
      await imported('Clipboard URL', true);
      final images = ImagePickerPlatform.instance;
      final scanner = MobileScannerPlatform.instance;
      ImagePickerPlatform.instance = _Images();
      MobileScannerPlatform.instance = _Scanner(
        'http://127.0.0.1:${server.port}/qr.yaml',
      );
      addTearDown(() {
        ImagePickerPlatform.instance = images;
        MobileScannerPlatform.instance = scanner;
      });
      await action.addProfileFormQrCode(useGlobalTemplate: true);
      await imported('qr.yaml', true);
      await action.addProfileFromClipboardContent(
        'ss://synthetic',
        'URI',
        true,
      );
      await imported('URI', true);
      await action.addProfileFromClipboardContent(
        base64Encode(utf8.encode('ss://synthetic')),
        'Base64',
        true,
      );
      await imported('Base64', true);
      await action.addProfileFromClipboardContent(yaml, 'Still off');
      await imported('Still off', false);
    },
  );
}
