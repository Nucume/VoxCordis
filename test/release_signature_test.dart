import 'dart:convert';

import 'package:companion/services/release_signature.dart';
import 'package:companion/services/updater.dart';
import 'package:flutter_test/flutter_test.dart';

// Made with the commands in docs/RELEASING.md and the release workflow:
// openssl genpkey -algorithm ed25519, then `openssl pkeyutl -sign -rawin`
// over the SHA-256 of a file holding "hello".
const _testKey = '''
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAXFBHx93vVqKdaiWff5osMHTRK622ySphxUYGHjnyrJI=
-----END PUBLIC KEY-----
''';
const _sha = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
final _sig = base64.decode(
  'AsL9CsUB0fergwzeJJ+IH69WzI4uEmxOf0K6fTCgapjFF8dbShYCA0DlHegGtuLwoo3O0/3cXINJqvzFBzdkDg==',
);

void main() {
  test('the release key is built in', () {
    expect(ReleaseSignature.required, isTrue);
    expect(ReleaseSignature.rawKey(releasePublicKey), hasLength(32));
  });

  test('accepts what openssl signed with the release key', () async {
    expect(
      await ReleaseSignature.verify(_sha, _sig, publicKeyPem: _testKey),
      isTrue,
    );
  });

  test('refuses another file, a changed signature or another key', () async {
    final other = 'ab' * 32;
    expect(
      await ReleaseSignature.verify(other, _sig, publicKeyPem: _testKey),
      isFalse,
    );
    final bent = [..._sig]..[0] ^= 1;
    expect(
      await ReleaseSignature.verify(_sha, bent, publicKeyPem: _testKey),
      isFalse,
    );
    expect(
      await ReleaseSignature.verify(_sha, _sig, publicKeyPem: 'nonsense'),
      isFalse,
    );
  });

  test('a build that knows the key needs a signature to update', () {
    Map<String, Object?> asset(String name) => {
      'name': name,
      'browser_download_url': 'https://github.com/x/y/releases/download/$name',
      'size': 4,
      'digest': 'sha256:$_sha',
    };
    final signed = {
      'tag_name': 'v0.3.0',
      'assets': [
        asset('VoxCordis-0.3.0-x86_64.AppImage.sig'),
        asset('VoxCordis-0.3.0-x86_64.AppImage'),
      ],
    };
    final info = parseRelease(
      signed,
      appImage: true,
      windows: false,
      requireSignature: true,
    )!;
    expect(info.assetUrl, endsWith('x86_64.AppImage'));
    expect(info.signatureUrl, endsWith('x86_64.AppImage.sig'));
    expect(info.canInstall, isTrue);

    final unsigned = {
      ...signed,
      'assets': [asset('VoxCordis-0.3.0-x86_64.AppImage')],
    };
    expect(
      parseRelease(
        unsigned,
        appImage: true,
        windows: false,
        requireSignature: true,
      )!.canInstall,
      isFalse,
    );
  });
}
