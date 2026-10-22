import 'package:flutter_test/flutter_test.dart';
import '../setup.dart' as setup;

void main() {
  test('literal v0.9.6-yf.2 tag becomes the owned release identity', () {
    expect(
      setup.createBuildEnvironment('stable', releaseVersion: 'v0.9.6-yf.2'),
      {'APP_ENV': 'stable', 'APP_RELEASE_VERSION': '0.9.6-yf.2'},
    );
  });
}
