import 'dart:async';
// ignore: depend_on_referenced_packages
import 'package:file/memory.dart';

import 'package:fl_clash/common/cache.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final class _MockCacheManager extends Mock implements CacheManager {}

void main() {
  FileInfo fileInfo({bool stale = false}) => FileInfo(
    MemoryFileSystem().file('unused-cache-file'),
    FileSource.Cache,
    DateTime.now().add(Duration(days: stale ? -1 : 1)),
    'url',
  );

  test('fresh cache emits once and skips remote and callback', () async {
    final cache = _MockCacheManager();
    final file = fileInfo();
    var callbacks = 0;
    when(() => cache.getFileFromCache('key')).thenAnswer((_) async => file);
    expect(
      await cache
          .getFileStreamV2(
            'url',
            key: 'key',
            onRemoteNewLoaded: () => callbacks++,
          )
          .toList(),
      [file],
    );
    expect(callbacks, 0);
    verifyNever(() => cache.downloadFile('url', key: 'key', authHeaders: null));
  });

  for (final fails in [false, true]) {
    test(
      'cancel during active remote suppresses delivery (fails=$fails)',
      () async {
        final cache = _MockCacheManager();
        final remote = Completer<FileInfo>();
        var callbacks = 0;
        final events = <FileInfo>[];
        when(() => cache.getFileFromCache('key')).thenAnswer((_) async => null);
        when(
          () => cache.downloadFile('url', key: 'key', authHeaders: null),
        ).thenAnswer((_) => remote.future);
        final subscription = cache
            .getFileStreamV2(
              'url',
              key: 'key',
              onRemoteNewLoaded: () => callbacks++,
            )
            .listen(events.add);
        await pumpEventQueue();
        verify(
          () => cache.downloadFile('url', key: 'key', authHeaders: null),
        ).called(1);
        await subscription.cancel();
        if (fails) {
          remote.completeError(StateError('remote failed'));
        } else {
          remote.complete(fileInfo());
        }
        await pumpEventQueue();
        expect(events, isEmpty);
        expect(callbacks, 0);
      },
    );
  }

  test('cancel during stale cache lookup does not refresh', () async {
    final cache = _MockCacheManager();
    final cached = Completer<FileInfo?>();
    when(() => cache.getFileFromCache('key')).thenAnswer((_) => cached.future);
    final subscription = cache
        .getFileStreamV2('url', key: 'key')
        .listen((_) {});
    await subscription.cancel();
    cached.complete(fileInfo(stale: true));
    await pumpEventQueue();
    verifyNever(() => cache.downloadFile('url', key: 'key', authHeaders: null));
  });

  test('cancelled cache lookup errors do not trigger remote refresh', () async {
    final cache = _MockCacheManager();
    final cached = Completer<FileInfo?>();
    when(() => cache.getFileFromCache('key')).thenAnswer((_) => cached.future);
    final subscription = cache
        .getFileStreamV2('url', key: 'key')
        .listen((_) {});
    await subscription.cancel();
    cached.completeError(StateError('cache failed'));
    await pumpEventQueue();
    verifyNever(() => cache.downloadFile('url', key: 'key', authHeaders: null));
  });

  test('cache miss delivers remote file and callback once', () async {
    final cache = _MockCacheManager();
    final remote = fileInfo();
    var callbacks = 0;
    when(() => cache.getFileFromCache('key')).thenAnswer((_) async => null);
    when(
      () => cache.downloadFile('url', key: 'key', authHeaders: null),
    ).thenAnswer((_) async => remote);
    expect(
      await cache
          .getFileStreamV2(
            'url',
            key: 'key',
            onRemoteNewLoaded: () => callbacks++,
          )
          .toList(),
      [remote],
    );
    expect(callbacks, 1);
  });

  test('cancelling the last listener avoids the remote download', () async {
    final cache = _MockCacheManager();
    final cached = Completer<FileInfo?>();
    when(() => cache.getFileFromCache('key')).thenAnswer((_) => cached.future);

    final stream = cache.getFileStreamV2('url', key: 'key');
    final subscription = stream.listen((_) {});
    await pumpEventQueue();
    await subscription.cancel();

    cached.complete(null);
    await pumpEventQueue();

    verify(() => cache.getFileFromCache('key')).called(1);
    verifyNever(() => cache.downloadFile('url', key: 'key', authHeaders: null));
  });
}
