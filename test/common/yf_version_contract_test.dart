import 'package:test/test.dart';
import 'package:fl_clash/common/package.dart';

void main() {
  test('YF release contract', () {
    final cases = <(String, String, int)>[
      ('0.9.3-yf.1', '0.9.3', 1),
      ('v0.9.3-yf.2', '0.9.3-yf.1', 1),
      ('v0.9.4-yf.1', '0.9.3-yf.99', 1),
      ('0.9.4-yf.10', '0.9.4-yf.2', 1),
      ('0.9.4', '0.9.4-rc.1', 1),
      ('0.9.4-beta.2', '0.9.4-beta.11', -1),
      ('0.9.3+12', '0.9.3+11', 1),
      ('0.9', '0.9.0', 0),
      ('V0.9.3+abc', '0.9.3', 0),
      ('0.9.3-yf.2+1', '0.9.3-yf.1+9999', 1),
      ('0.9.3-yf.1', '0.9.3+2026100700', 1),
      ('0.9.4-yf.1', '0.9.5-rc.1', -1),
    ];
    for (final (a, b, result) in cases) {
      final actual = compareVersions(a, b).sign;
      if (actual != result || compareVersions(b, a).sign != -result) {
        throw StateError('$a vs $b: $actual != $result');
      }
    }
    for (final invalid in [
      '0.9.3-yf.0',
      '0.9.3-yf.01',
      'vgarbage',
      '0.9.3-rc..1',
    ]) {
      try {
        compareVersions(invalid, '0.9.3');
        throw StateError('accepted invalid $invalid');
      } on FormatException {
        /* expected */
      }
    }
    expect(cases, hasLength(12));
  });
}
