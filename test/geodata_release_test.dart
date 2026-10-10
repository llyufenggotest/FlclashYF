import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/geo_assets.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../tool/geodata.dart' as geodata;

/// Real resources extracted from the 0.9.3 APK. Override with GEO_RAW_DIR.
final rawDir =
    Platform.environment['GEO_RAW_DIR'] ??
    'F:/Temp/oix-test/evidence/flclashyf-geodata-094/raw';

const names = [
  'GeoIP.metadb',
  'GeoIP.dat',
  'GeoSite.dat',
  'ASN.mmdb',
  'BundleMRS.7z',
];

void main() {
  late Directory root;
  late HttpServer server;
  late Map<String, Uint8List> originals;
  late String dataDir;

  Future<Uint8List> load(String asset) async =>
      File(p.join(dataDir, p.basename(asset))).readAsBytes();

  Future<String> sha(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();

  setUpAll(() async {
    originals = {};
    for (final n in names) {
      final f = File(p.join(rawDir, n));
      // BundleMRS.7z is not part of the APK sample; synthesize opaque bytes.
      originals[n] = f.existsSync()
          ? f.readAsBytesSync()
          : Uint8List.fromList(List.generate(65536, (i) => (i * 31) % 256));
    }
    root = await Directory.systemTemp.createTemp('geo_release_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.add(originals[p.basename(req.uri.path)]!);
      await req.response.close();
    });
    final sw = Stopwatch()..start();
    await geodata.ensureGeoData(
      rootDir: root.path,
      sources: {
        for (final n in names)
          n: 'http://${server.address.address}:${server.port}/$n',
      },
    );
    stdout.writeln('pack(build) ms=${sw.elapsedMilliseconds}');
    dataDir = p.join(root.path, 'assets', 'data');
  });

  tearDownAll(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test('manifest: four packed losslessly, BundleMRS shipped raw', () async {
    final m =
        jsonDecode(
              File(p.join(dataDir, geodata.geoManifestName)).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final entries = (m['resources'] as List).cast<Map<String, dynamic>>();
    expect(entries.length, 5);
    var raw = 0, packed = 0;
    for (final e in entries) {
      final name = e['name'] as String;
      final asset = File(p.join(dataDir, e['asset'] as String));
      expect(e['size'], originals[name]!.length);
      expect(e['sha256'], sha256.convert(originals[name]!).toString());
      if (name == 'BundleMRS.7z') {
        expect(e['codec'], 'none');
        continue;
      }
      expect(e['codec'], anyOf('xz', 'zlib'));
      expect(
        File(p.join(dataDir, name)).existsSync(),
        isFalse,
        reason: 'raw copy must not be bundled',
      );
      raw += originals[name]!.length;
      packed += asset.lengthSync();
      stdout.writeln(
        '$name raw=${originals[name]!.length} '
        '${e['codec']}=${asset.lengthSync()}',
      );
    }
    stdout.writeln('four total raw=$raw packed=$packed');
  });

  test(
    'cold start installs byte-identical files; second start keeps them',
    () async {
      final home = await Directory(p.join(root.path, 'home1')).create();
      final sw = Stopwatch()..start();
      final r1 = await installGeoAssets(
        homePath: home.path,
        names: names,
        loadAsset: load,
      );
      stdout.writeln('cold install ms=${sw.elapsedMilliseconds} $r1');
      expect(
        r1.every((r) => r.status == GeoInstallStatus.installed),
        isTrue,
        reason: '$r1',
      );
      for (final n in names) {
        final f = File(p.join(home.path, n));
        expect(
          await sha(f),
          sha256.convert(originals[n]!).toString(),
          reason: n,
        );
      }
      final mtimes = {
        for (final n in names) n: File(p.join(home.path, n)).lastModifiedSync(),
      };
      sw.reset();
      final r2 = await installGeoAssets(
        homePath: home.path,
        names: names,
        loadAsset: load,
      );
      stdout.writeln('second start ms=${sw.elapsedMilliseconds}');
      expect(
        r2.every((r) => r.status == GeoInstallStatus.keptExisting),
        isTrue,
      );
      for (final n in names) {
        expect(File(p.join(home.path, n)).lastModifiedSync(), mtimes[n]);
      }
    },
  );

  test(
    'user/custom files are never overwritten; empty file reported',
    () async {
      final home = await Directory(p.join(root.path, 'home2')).create();
      File(p.join(home.path, 'GeoSite.dat')).writeAsStringSync('custom');
      File(p.join(home.path, 'ASN.mmdb')).writeAsBytesSync([]);
      final r = await installGeoAssets(
        homePath: home.path,
        names: names,
        loadAsset: load,
      );
      final byName = {for (final x in r) x.name: x.status};
      expect(byName['GeoSite.dat'], GeoInstallStatus.keptExisting);
      expect(byName['ASN.mmdb'], GeoInstallStatus.suspicious);
      expect(
        File(p.join(home.path, 'GeoSite.dat')).readAsStringSync(),
        'custom',
      );
      expect(File(p.join(home.path, 'ASN.mmdb')).lengthSync(), 0);
      expect(byName['GeoIP.dat'], GeoInstallStatus.installed);
    },
  );

  test(
    'interrupted install recovers; corrupt payload reported, no partial',
    () async {
      final home = await Directory(p.join(root.path, 'home3')).create();
      // Simulated crash mid-extract: stale temp left behind, target missing.
      final stale = File(p.join(home.path, 'GeoIP.dat$geoTempSuffix.999'))
        ..writeAsBytesSync(List.filled(1000, 7));
      // Corrupt GeoIP.metadb payload (truncate packed asset).
      Future<Uint8List> corruptLoad(String asset) async {
        final b = await load(asset);
        return p.basename(asset).startsWith('GeoIP.metadb.')
            ? Uint8List.sublistView(b, 0, b.length ~/ 2)
            : b;
      }

      final r = await installGeoAssets(
        homePath: home.path,
        names: names,
        loadAsset: corruptLoad,
      );
      final byName = {for (final x in r) x.name: x};
      expect(stale.existsSync(), isFalse);
      expect(byName['GeoIP.dat']!.status, GeoInstallStatus.installed);
      expect(
        await sha(File(p.join(home.path, 'GeoIP.dat'))),
        sha256.convert(originals['GeoIP.dat']!).toString(),
      );
      expect(byName['GeoIP.metadb']!.status, GeoInstallStatus.failed);
      expect(File(p.join(home.path, 'GeoIP.metadb')).existsSync(), isFalse);
      expect(
        home.listSync().where((e) => e.path.contains(geoTempSuffix)),
        isEmpty,
      );
      // Next start with a good bundle completes the install.
      final r2 = await installGeoAssets(
        homePath: home.path,
        names: ['GeoIP.metadb'],
        loadAsset: load,
      );
      expect(r2.single.status, GeoInstallStatus.installed);
      expect(
        await sha(File(p.join(home.path, 'GeoIP.metadb'))),
        sha256.convert(originals['GeoIP.metadb']!).toString(),
      );
    },
  );
}
