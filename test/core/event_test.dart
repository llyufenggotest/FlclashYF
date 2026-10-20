import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _BrokenBatchListener with CoreEventListener {
  @override
  void onBatchStart() => throw StateError('batch start');
  @override
  void onBatchEnd() => throw StateError('batch end');
  @override
  void onLog(Log log) => throw StateError('log dispatch');
}

class _RecordingListener with CoreEventListener {
  _RecordingListener({this.onLoadedCallback});

  final void Function()? onLoadedCallback;
  final List<String> loaded = [];
  final List<Log> logs = [];

  @override
  void onLog(Log log) {
    logs.add(log);
  }

  @override
  void onLoaded(String providerName) {
    loaded.add(providerName);
    onLoadedCallback?.call();
  }
}

void main() {
  test(
    'batch listener failures and malformed models do not drop later events',
    () async {
      final broken = _BrokenBatchListener();
      final good = _RecordingListener();
      coreEventManager.addListener(broken);
      coreEventManager.addListener(good);
      addTearDown(() {
        coreEventManager.removeListener(broken);
        coreEventManager.removeListener(good);
      });
      coreEventManager.sendEvents(const [
        CoreEvent(
          type: CoreEventType.log,
          data: {'LogLevel': 'info', 'Payload': 'before'},
        ),
        CoreEvent(type: CoreEventType.request, data: {'metadata': 42}),
        CoreEvent(
          type: CoreEventType.log,
          data: {'LogLevel': 'error', 'Payload': 'after'},
        ),
      ]);
      await pumpEventQueue();
      expect(good.logs.map((l) => l.payload), ['before', 'after']);
    },
  );

  test('live Core logs carry the Core source', () async {
    final listener = _RecordingListener();
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.log,
        data: {'LogLevel': 'info', 'Payload': 'Core log'},
      ),
    );
    await pumpEventQueue();

    final log = listener.logs.single;
    expect(log.source, LogSource.core);
    expect(log.logLevel, LogLevel.info);
    expect(log.payload, 'Core log');
    expect(LogsState(logs: [log], sources: {LogSource.app}).list, isEmpty);
    expect(LogsState(logs: [log], sources: {LogSource.core}).list, [log]);
  });

  test(
    'a listener may unregister itself while an event is dispatched',
    () async {
      late _RecordingListener first;
      final second = _RecordingListener();
      first = _RecordingListener(
        onLoadedCallback: () => coreEventManager.removeListener(first),
      );

      coreEventManager.addListener(first);
      coreEventManager.addListener(second);
      addTearDown(() {
        coreEventManager.removeListener(first);
        coreEventManager.removeListener(second);
      });

      coreEventManager.sendEvent(
        const CoreEvent(type: CoreEventType.loaded, data: 'provider-a'),
      );
      await pumpEventQueue();

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, ['provider-a']);

      coreEventManager.sendEvent(
        const CoreEvent(type: CoreEventType.loaded, data: 'provider-b'),
      );
      await pumpEventQueue();

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, ['provider-a', 'provider-b']);
    },
  );
}
