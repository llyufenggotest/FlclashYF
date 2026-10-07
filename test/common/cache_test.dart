import 'dart:async';

import 'package:fl_clash/common/cache.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final class _MockCacheManager extends Mock implements CacheManager {}

void main() {
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
