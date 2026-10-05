import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level contract for the reclaim/battery fix.
///
/// The 2026-09-01 tester trace (`FlClash_2026-09-01.log`, 759 s of tunnel
/// uptime across 12 lives) measured what the unconditional reclaim trigger
/// actually cost:
///
///   footprint_mb: min=19 p50=38 p90=42 p99=43 max=48
///   >=38MB (reclaim threshold): 388/763 samples = 50.9%
///   memory_pressure_reclaim fired 32 times
///     effective:   42->35 MB, 48->23 MB          (2)
///     no-op:       38->38, 41->41, 42->42, ...   (30)
///   heartbeat lines: 763 in 759 s = 1.01/s
///
/// So the reclaim threshold sat exactly on the steady-state median, and 30 of
/// 32 whole-heap `FreeOSMemory()` walks freed nothing. That periodic no-op GC
/// plus one App Group file append per second is the battery drain the user
/// asked about. The 48->23 MB case is why the backstop must survive: that
/// reclaim is what kept the tunnel alive at the death line.
void main() {
  String source(String path) => File(path).readAsStringSync();

  group('reclaim stops paying for whole-heap walks that free nothing', () {
    test('the escalation rule is a pure, testable function', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      expect(heartbeat, contains('static func nextReclaimPolicy('));
      expect(heartbeat, contains('current: ReclaimPolicy'));
      expect(heartbeat, contains('yieldMB: Int'));
    });

    test('reclaim yield is measured, not assumed', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      // before - after, computed from a fresh sample taken after the walk.
      expect(
        heartbeat,
        contains('let yieldMB = usage.footprintMB - after.footprintMB'),
      );
      expect(heartbeat, contains('minEffectiveYieldMB'));
    });

    test('an effective reclaim resets to the aggressive base policy', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      final start = heartbeat.indexOf('static func nextReclaimPolicy(');
      final end = heartbeat.indexOf('// MARK: - Log throttling');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = heartbeat.substring(start, end);
      expect(body, contains('guard yieldMB < minEffectiveYieldMB else {'));
      expect(body, contains('return baseReclaimPolicy'));
    });

    test(
      'consecutive no-op reclaims escalate threshold and back off cooldown',
      () {
        final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
        expect(heartbeat, contains('ineffectiveStreakLimit'));
        expect(heartbeat, contains('escalatedReclaimMB'));
        expect(
          heartbeat,
          contains('min(current.cooldown * 2, maxReclaimCooldown)'),
        );
        expect(
          heartbeat,
          contains('max(current.thresholdMB, escalatedReclaimMB)'),
          reason: 'escalation must never lower the threshold back down',
        );
      },
    );

    test('the backstop still fires before the 48 MB death line', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      // 44 leaves a reaction window under the observed 48 MB ceiling, so the
      // 48->23 MB save in the trace still happens after escalation.
      expect(heartbeat, contains('escalatedReclaimMB = 44'));
      expect(heartbeat, contains('maxReclaimCooldown: TimeInterval = 120'));
    });

    test('the live policy drives the trigger, not the raw constant', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      expect(
        heartbeat,
        contains('usage.footprintMB >= self.reclaimPolicy.thresholdMB'),
      );
      expect(heartbeat, contains('cooldown: self.reclaimPolicy.cooldown'));
    });

    test('the reclaim outcome is observable in the durable log', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      // Without the yield in the log there is no way to tell an effective
      // reclaim from a no-op in a tester trace, which is how 30 wasted walks
      // went unnoticed in the first place.
      expect(heartbeat, contains('yield_mb=\\(yieldMB)'));
      expect(heartbeat, contains('next_threshold_mb='));
      expect(heartbeat, contains('next_cooldown_s='));
    });

    test('policy is reset per tunnel life', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      final start = heartbeat.indexOf('func start() {');
      final end = heartbeat.indexOf('let timer = DispatchSource', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = heartbeat.substring(start, end);
      expect(body, contains('reclaimPolicy = Self.baseReclaimPolicy'));
    });
  });

  group('heartbeat logging is throttled without losing the danger window', () {
    test('the throttle is a pure, testable function', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      expect(heartbeat, contains('static func shouldLogHeartbeat('));
      expect(heartbeat, contains('lastLoggedFootprintMB: Int'));
    });

    test('samples in the real run-up to jetsam are never throttled', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      final start = heartbeat.indexOf('static func shouldLogHeartbeat(');
      final end = heartbeat.indexOf('/// Injected so the heartbeat', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = heartbeat.substring(start, end);
      // Keyed off the escalated threshold, not the warning one: with a p50 of
      // 38 MB, exempting everything over the 30 MB warning line would exempt
      // 96.5% of samples and defeat the throttle entirely.
      expect(
        body,
        contains('if footprintMB >= escalatedReclaimMB { return true }'),
      );
      expect(
        body,
        isNot(contains('footprintMB >= footprintWarningMB { return true }')),
        reason: 'the warning line sits below the steady-state median',
      );
    });

    test('a material footprint move is always logged', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      expect(heartbeat, contains('logDeltaMB'));
      expect(
        heartbeat,
        contains('abs(footprintMB - lastLoggedFootprintMB) >= logDeltaMB'),
      );
    });

    test('a healthy plateau falls back to a slow liveness cadence', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      expect(heartbeat, contains('logIntervalSeconds: TimeInterval = 10'));
      expect(
        heartbeat,
        contains('uptimeSeconds - lastLoggedUptime >= logIntervalSeconds'),
      );
    });

    test('the sample itself still runs every second', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      // Two task_info counter reads are microseconds; throttling the *sample*
      // would blind the reaction window. Only the file append is throttled.
      expect(heartbeat, contains('repeating: .seconds(1)'));
      expect(heartbeat, contains('leeway: .milliseconds(200)'));
    });

    test('throttle state is reset per tunnel life', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      final start = heartbeat.indexOf('func start() {');
      final end = heartbeat.indexOf('let timer = DispatchSource', start);
      final body = heartbeat.substring(start, end);
      expect(body, contains('lastLoggedUptime = -.greatestFiniteMagnitude'));
      expect(body, contains('lastLoggedFootprintMB = Int.min'));
    });
  });

  group('the existing memory contracts still hold', () {
    test('base thresholds are unchanged', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      expect(heartbeat, contains('footprintWarningMB = 30'));
      expect(heartbeat, contains('footprintReclaimMB = 38'));
      expect(heartbeat, contains('reclaimCooldown: TimeInterval = 15'));
    });

    test('admission control remains the primary defence', () {
      final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
      final profileBudget = source('lib/common/ios_profile_budget.dart');
      expect(heartbeat, contains('iOS profile sanitization'));
      expect(profileBudget, contains('iosPreConnectCap = 2'));
      expect(profileBudget, contains('iosMinHealthCheckInterval = 300'));
    });
  });
}
