import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:companion/services/updater.dart' show updateRepo;
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

  test('reads release tags from the releases feed, newest first', () {
    const feed = '''
<feed><entry><link rel="alternate" type="text/html" href="https://github.com/Nucume/VoxCordis/releases/tag/v0.4.2-test.1"/></entry>
<entry><link rel="alternate" type="text/html" href="https://github.com/Nucume/VoxCordis/releases/tag/v0.4.1"/></entry></feed>''';
    expect(releaseTagsFromFeed(feed, 'Nucume/VoxCordis'), [
      'v0.4.2-test.1',
      'v0.4.1',
    ]);
  });

  test('falls back to the releases feed when the API answers 403', () async {
    if (!updateRepo.contains('/')) return; // no release repository built in
    final asked = <String>[];
    final client = MockClient((req) async {
      final u = req.url.toString();
      asked.add('${req.method} $u');
      if (!u.endsWith('.tar.gz')) {
        expect(req.headers['User-Agent'], 'VoxCordis');
      }
      if (u.startsWith('https://api.github.com/')) {
        return http.Response(
          '{"message":"API rate limit exceeded"}',
          403,
          headers: {'x-ratelimit-remaining': '0'},
        );
      }
      if (u.endsWith('/releases.atom')) {
        return http.Response(
          '<link href="https://github.com/$updateRepo/releases/tag/v2"/>'
          '<link href="https://github.com/$updateRepo/releases/tag/v1"/>',
          200,
        );
      }
      if (u.contains('/download/v1/')) {
        return http.Response(u.endsWith('.sig') ? 'x' * 64 : 'archive', 200);
      }
      return http.Response('Not Found', 404);
    });
    final tmp = await Directory.systemTemp.createTemp('signed');
    addTearDown(() => tmp.delete(recursive: true));
    final notes = <String>[];
    final got = await installSignedReleaseAsset(
      client,
      asset: asset,
      into: Directory('${tmp.path}/into'),
      downloads: Directory('${tmp.path}/dl'),
      note: notes.add,
    );
    // The test file isn't signed by the release key, so it is refused,
    // but only after it was found under v1 without the API.
    expect(got, SignedAssetResult.notPublished, reason: notes.join());
    expect(notes.single, contains('signature did not check out'));
    expect(
      asked,
      contains(
        'GET https://github.com/$updateRepo/releases/download/v1/$asset',
      ),
    );
    expect(await File('${tmp.path}/dl/$asset').exists(), isFalse);
  });

  test('says when the API limit is used up and nothing else works', () async {
    if (!updateRepo.contains('/')) return;
    final client = MockClient(
      (req) async => req.url.host == 'api.github.com'
          ? http.Response('', 403, headers: {'x-ratelimit-remaining': '0'})
          : http.Response('', 403),
    );
    final notes = <String>[];
    final got = await installSignedReleaseAsset(
      client,
      asset: asset,
      into: Directory.systemTemp,
      downloads: Directory.systemTemp,
      note: notes.add,
    );
    expect(got, SignedAssetResult.failed);
    expect(notes.single, contains('60 calls an hour'));
  });
}
