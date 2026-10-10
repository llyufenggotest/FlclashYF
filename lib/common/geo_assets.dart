import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Bundled manifest describing release-packed Geo resources.
const geoManifestAsset = 'assets/data/geo-manifest.json';
const geoTempSuffix = '.geo-install';

enum GeoInstallStatus { installed, keptExisting, suspicious, failed }

class GeoInstallResult {
  final String name;
  final GeoInstallStatus status;
  final String? message;

  const GeoInstallResult(this.name, this.status, [this.message]);

  @override
  String toString() =>
      '$name: ${status.name}${message == null ? '' : ' ($message)'}';
}

class GeoManifestEntry {
  final String name;
  final String asset;
  final String codec;
  final int size;
  final String sha256;

  const GeoManifestEntry({
    required this.name,
    required this.asset,
    required this.codec,
    required this.size,
    required this.sha256,
  });

  factory GeoManifestEntry.fromJson(Map<String, dynamic> json) {
    return GeoManifestEntry(
      name: json['name'] as String,
      asset: json['asset'] as String,
      codec: json['codec'] as String,
      size: json['size'] as int,
      sha256: json['sha256'] as String,
    );
  }
}

typedef GeoAssetLoader = Future<Uint8List> Function(String assetPath);

/// Installs missing Geo resources into [homePath] under their original names.
///
/// Existing files are never overwritten (they may be user-customized). A
/// missing file is decoded into a temp file, verified against the manifest
/// size/SHA-256, then atomically renamed into place. Without a manifest the
/// legacy raw asset `assets/data/<name>` is copied with the same temp+rename.
Future<List<GeoInstallResult>> installGeoAssets({
  required String homePath,
  required List<String> names,
  required GeoAssetLoader loadAsset,
}) async {
  Map<String, GeoManifestEntry>? manifest;
  try {
    final raw = utf8.decode(await loadAsset(geoManifestAsset));
    final json = jsonDecode(raw) as Map<String, dynamic>;
    manifest = {
      for (final item in json['resources'] as List)
        (item['name'] as String): GeoManifestEntry.fromJson(
          (item as Map).cast<String, dynamic>(),
        ),
    };
  } catch (_) {
    manifest = null;
  }

  final results = <GeoInstallResult>[];
  for (final name in names) {
    final target = File(p.join(homePath, name));
    try {
      _removeStaleTemps(homePath, name);
      if (await target.exists()) {
        final length = await target.length();
        results.add(
          length == 0
              ? GeoInstallResult(
                  name,
                  GeoInstallStatus.suspicious,
                  'existing file is empty; left untouched',
                )
              : GeoInstallResult(name, GeoInstallStatus.keptExisting),
        );
        continue;
      }
      final entry = manifest?[name];
      final assetPath = entry == null
          ? 'assets/data/$name'
          : 'assets/data/${entry.asset}';
      final payload = await loadAsset(assetPath);
      final temp = '${target.path}$geoTempSuffix.$pid';
      final error = await Isolate.run(
        () => _decodeVerifyPublish(
          payload: payload,
          codec: entry?.codec ?? 'none',
          expectedSize: entry?.size,
          expectedSha256: entry?.sha256,
          tempPath: temp,
          targetPath: target.path,
        ),
      );
      results.add(
        error == null
            ? GeoInstallResult(name, GeoInstallStatus.installed)
            : GeoInstallResult(name, GeoInstallStatus.failed, error),
      );
    } catch (e) {
      results.add(GeoInstallResult(name, GeoInstallStatus.failed, '$e'));
    }
  }
  return results;
}

void _removeStaleTemps(String homePath, String name) {
  final dir = Directory(homePath);
  if (!dir.existsSync()) return;
  final prefix = '$name$geoTempSuffix';
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is File && p.basename(entity.path).startsWith(prefix)) {
      try {
        entity.deleteSync();
      } catch (_) {}
    }
  }
}

/// Returns null on success, otherwise an error description. Never leaves a
/// partial file at [targetPath].
Future<String?> _decodeVerifyPublish({
  required Uint8List payload,
  required String codec,
  required int? expectedSize,
  required String? expectedSha256,
  required String tempPath,
  required String targetPath,
}) async {
  final temp = File(tempPath);
  try {
    switch (codec) {
      case 'xz':
        final out = OutputFileStream(tempPath);
        try {
          XZDecoder().decodeStream(
            InputMemoryStream(payload),
            out,
            verify: true,
            throwOnError: true,
          );
        } finally {
          await out.close();
        }
      case 'zlib':
        final sink = temp.openWrite();
        try {
          await Stream<List<int>>.value(
            payload,
          ).transform(zlib.decoder).pipe(sink);
        } catch (_) {
          await sink.close().catchError((_) {});
          rethrow;
        }
      case 'none':
        await temp.writeAsBytes(payload, flush: true);
      default:
        return 'unknown codec $codec';
    }
    if (expectedSize != null || expectedSha256 != null) {
      final size = await temp.length();
      if (expectedSize != null && size != expectedSize) {
        return 'size mismatch: $size != $expectedSize';
      }
      final digest = await sha256.bind(temp.openRead()).first;
      if (expectedSha256 != null && digest.toString() != expectedSha256) {
        return 'sha256 mismatch: $digest';
      }
    }
    if (File(targetPath).existsSync()) {
      // Appeared concurrently (user or another process): do not overwrite.
      return null;
    }
    await temp.rename(targetPath);
    return null;
  } catch (e) {
    return '$e';
  } finally {
    if (temp.existsSync()) {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
  }
}
