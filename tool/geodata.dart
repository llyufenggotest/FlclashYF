import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const geoDataSources = {
  'BundleMRS.7z':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/BundleMRS.7z',
  'GeoIP.metadb':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb',
  'ASN.mmdb':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb',
  'GeoIP.dat':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
  'GeoSite.dat':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
};

/// Already-compressed resources are shipped unchanged.
const geoDataUnpacked = {'BundleMRS.7z'};
const geoManifestName = 'geo-manifest.json';

/// Downloads raw Geo resources into `.dart_tool/geodata` (build cache) and
/// publishes release payloads into `assets/data/`. Raw-format databases are
/// losslessly compressed (xz -6 via the `xz` CLI; zlib fallback when xz is not
/// installed) and described in [geoManifestName] with original size/SHA-256.
/// Both directories are git-ignored, so large files never enter git.
Future<void> ensureGeoData({
  required String rootDir,
  Map<String, String> sources = geoDataSources,
  bool? useXz,
}) async {
  final dataDir = Directory(p.join(rootDir, 'assets', 'data'));
  final cacheDir = Directory(p.join(rootDir, '.dart_tool', 'geodata'));
  dataDir.createSync(recursive: true);
  cacheDir.createSync(recursive: true);
  final xzAvailable = useXz ?? await _hasXz();

  final resources = <Map<String, Object>>[];
  for (final entry in sources.entries) {
    if (!geoDataSources.containsKey(entry.key)) {
      throw ArgumentError('Unknown Geo resource: ${entry.key}');
    }
    final raw = File(p.join(cacheDir.path, entry.key));
    final fresh =
        raw.existsSync() &&
        raw.lastModifiedSync().isAfter(
          DateTime.now().subtract(const Duration(days: 1)),
        );
    if (!fresh) {
      if (raw.existsSync()) {
        stdout.writeln('GeoData is outdated: ${entry.key}');
      }
      await _downloadGeoData(url: entry.value, file: raw);
    }
    final size = raw.lengthSync();
    final digest = (await sha256.bind(raw.openRead()).first).toString();

    final legacy = File(p.join(dataDir.path, entry.key));
    final String asset;
    final String codec;
    if (geoDataUnpacked.contains(entry.key)) {
      asset = entry.key;
      codec = 'none';
      await _atomicCopy(raw, legacy);
    } else {
      codec = xzAvailable ? 'xz' : 'zlib';
      asset = '${entry.key}.$codec';
      final packed = File(p.join(dataDir.path, asset));
      final tmp = File('${packed.path}.tmp');
      if (codec == 'xz') {
        // -6 keeps the LZMA2 dictionary at 8 MiB for mobile decode memory.
        final args = ['-6', '-c', '-T1', '--check=crc64', raw.path];
        final r = await Process.run('xz', args, stdoutEncoding: null);
        if (r.exitCode != 0) {
          throw ProcessException('xz', args, '${r.stderr}', r.exitCode);
        }
        tmp.writeAsBytesSync(r.stdout as List<int>, flush: true);
      } else {
        tmp.writeAsBytesSync(
          ZLibEncoder(level: 9).convert(raw.readAsBytesSync()),
          flush: true,
        );
      }
      if (packed.existsSync()) packed.deleteSync();
      tmp.renameSync(packed.path);
      // Remove raw/other-codec copies so Flutter does not bundle duplicates.
      final other = codec == 'xz' ? 'zlib' : 'xz';
      for (final stale in [
        legacy,
        File(p.join(dataDir.path, '${entry.key}.$other')),
      ]) {
        if (stale.existsSync()) stale.deleteSync();
      }
    }
    resources.add({
      'name': entry.key,
      'asset': asset,
      'codec': codec,
      'size': size,
      'sha256': digest,
    });
  }
  File(p.join(dataDir.path, geoManifestName)).writeAsStringSync(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'version': 1, 'resources': resources}),
  );
}

Future<bool> _hasXz() async {
  try {
    return (await Process.run('xz', ['--version'])).exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _atomicCopy(File from, File to) async {
  final tmp = File('${to.path}.tmp');
  await from.copy(tmp.path);
  if (to.existsSync()) to.deleteSync();
  tmp.renameSync(to.path);
}

Future<void> _downloadGeoData({required String url, required File file}) async {
  final tempFile = File('${file.path}.download');
  stdout.writeln('Downloading GeoData: ${p.basename(file.path)}');

  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Failed to download $url: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    await response.pipe(tempFile.openWrite());
    if (file.existsSync()) {
      file.deleteSync();
    }
    tempFile.renameSync(file.path);
  } catch (_) {
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}
