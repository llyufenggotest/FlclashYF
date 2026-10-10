import 'package:fl_clash/common/app_update.dart';
import 'package:test/test.dart';

const hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const name = 'FlClash-0.9.4-windows-x64-setup.exe';
const ownUrl =
    'https://github.com/llyufenggotest/FlclashYF/releases/download/v0.9.4-yf.1/$name';
ReleaseAsset asset({
  String assetName = name,
  String url = ownUrl,
  String sha = hash,
  int size = 1,
}) => ReleaseAsset(name: assetName, url: url, size: size, sha256: sha);
AppUpdatePlan? plan(List<ReleaseAsset> assets, {String tag = 'v0.9.4-yf.1'}) =>
    planAppUpdate(
      ReleaseManifest(tag: tag, notes: '', assets: assets),
      const UpdateTarget(UpdatePackage.windowsInstaller, 'x64'),
    );

void main() {
  test('accepts only the exact own release asset', () {
    expect(plan([asset()])?.asset.name, name);
    expect(
      browserDownloadUri(null).toString(),
      'https://github.com/llyufenggotest/FlclashYF/releases/latest',
    );
  });
  test('rejects upstream and foreign URL or mismatched basename', () {
    for (final url in [
      ownUrl.replaceAll(
        'llyufenggotest/FlclashYF',
        'chenx-dust/FlClash-Patched',
      ),
      ownUrl.replaceAll('github.com', 'github.com.evil.test'),
      ownUrl.replaceAll('https:', 'http:'),
      '$ownUrl?other=1',
      '$ownUrl#fragment',
      ownUrl.replaceAll('v0.9.4-yf.1', 'v0.9.4-yf.2'),
      ownUrl.replaceAll(name, 'wrong.exe'),
    ]) {
      expect(plan([asset(url: url)]), isNull, reason: url);
    }
  });
  test('rejects duplicate, wrong version, bad hash and empty payload', () {
    expect(plan([asset(), asset()]), isNull);
    expect(plan([asset(assetName: name.replaceAll('0.9.4', '0.9.3'))]), isNull);
    expect(plan([asset(sha: 'abc')]), isNull);
    expect(plan([asset(size: 0)]), isNull);
    expect(plan([asset()], tag: 'v0.9.4'), isNull);
    expect(plan([asset()], tag: 'v0.9.4-yf.01'), isNull);
  });
  test('unverified in-place install remains disabled', () {
    for (final package in UpdatePackage.values) {
      expect(package.updatesInApp, isFalse, reason: package.name);
    }
  });
}
