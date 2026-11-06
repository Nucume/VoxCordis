import 'package:flutter_test/flutter_test.dart';
import 'package:companion/services/runtime/signed_release_asset.dart';

Map<String, Object?> _asset(String name) => {
  'name': name,
  'digest': 'sha256:${'a' * 64}',
  'browser_download_url': 'https://example.com/$name',
};

void main() {
  const asset = 'sd-cli-cuda-master-920-2f88688-linux-x64.tar.gz';

  test('takes the newest release that has the signed asset', () {
    final releases = [
      {
        'tag_name': 'v0.4.3',
        'assets': [_asset('VoxCordis-0.4.3-x86_64.AppImage')],
      },
      {
        'tag_name': 'v0.4.2-test.1',
        'prerelease': true,
        'assets': [_asset(asset), _asset('$asset.sig')],
      },
      {
        'tag_name': 'v0.4.1',
        'assets': [_asset(asset), _asset('$asset.sig')],
      },
    ];
    final found = newestSignedAsset(releases, asset);
    expect(found, isNotNull);
    expect(found!.file['browser_download_url'], 'https://example.com/$asset');
    expect(found.sha, 'a' * 64);
    // The pre-release, not v0.4.1.
    expect((releases[1]['assets']! as List).contains(found.file), isTrue);
  });

  test('skips drafts and assets without a signature', () {
    final releases = [
      {
        'draft': true,
        'assets': [_asset(asset), _asset('$asset.sig')],
      },
      {
        'assets': [_asset(asset)],
      },
    ];
    expect(newestSignedAsset(releases, asset), isNull);
    expect(newestSignedAsset({'message': 'Not Found'}, asset), isNull);
  });
}
