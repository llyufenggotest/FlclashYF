import 'dart:async';
import 'dart:ui';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

extension CacheManagerExt on CacheManager {
  Stream<FileInfo> getFileStreamV2(
    String url, {
    String? key,
    Map<String, String>? headers,
    VoidCallback? onRemoteNewLoaded,
  }) {
    key ??= url;
    final streamController = StreamController<FileInfo>();
    var cancelled = false;
    streamController.onCancel = () => cancelled = true;
    _pushFileToStream(
      streamController,
      url,
      key,
      headers,
      onRemoteNewLoaded,
      () => cancelled,
    );
    return streamController.stream;
  }

  Future<void> _pushFileToStream(
    StreamController<dynamic> streamController,
    String url,
    String? key,
    Map<String, String>? headers,
    VoidCallback? onRemoteNewLoaded,
    bool Function()? isCancelled,
  ) async {
    key ??= url;
    FileInfo? cacheFile;
    try {
      cacheFile = await getFileFromCache(key);
      if (cacheFile != null) {
        streamController.add(cacheFile);
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to load cached file for $url with error:\n$e',
        CacheManagerLogLevel.debug,
      );
    }
    if (isCancelled?.call() == true) {
      unawaited(streamController.close());
      return;
    }
    if (cacheFile == null || cacheFile.validTill.isBefore(DateTime.now())) {
      try {
        final res = (await downloadFile(url, key: key, authHeaders: headers));
        if (isCancelled?.call() != true) {
          streamController.add(res);
          if (cacheFile == null) {
            onRemoteNewLoaded?.call();
          }
        }
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Failed to download file from $url with error:\n$e',
          CacheManagerLogLevel.debug,
        );
      }
    }
    unawaited(streamController.close());
  }
}
