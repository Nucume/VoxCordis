import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// The public half of the key that signs every release (the repository
/// secret RELEASE_SIGNING_KEY), as `openssl pkey -pubout` prints it.
///
/// The updater only installs a file whose SHA-256 carries a valid signature
/// from this key, so whoever could publish a release without it (with a
/// stolen release token, say) still can't get anything installed.
const releasePublicKey = '''
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA0jgFmjUg26G45nlJH0yBzUetZlpbnwZeYVDuNIy4Kd4=
-----END PUBLIC KEY-----
''';

/// Checks the `<file>.sig` that the release workflow publishes next to each
/// installer: an Ed25519 signature over the file's SHA-256, written as 64
/// lowercase hex characters.
class ReleaseSignature {
  /// Whether this build checks signatures at all; true once
  /// [releasePublicKey] is filled in.
  static bool get required => releasePublicKey.trim().isNotEmpty;

  /// Whether [signature] is the release key's signature of [sha256Hex].
  static Future<bool> verify(
    String sha256Hex,
    List<int> signature, {
    String publicKeyPem = releasePublicKey,
  }) async {
    if (signature.length != 64) return false;
    final key = rawKey(publicKeyPem);
    if (key == null) return false;
    try {
      return await Ed25519().verify(
        utf8.encode(sha256Hex.toLowerCase()),
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }

  /// The 32 raw key bytes inside a PEM `PUBLIC KEY` block, or null when it
  /// isn't an Ed25519 key.
  static List<int>? rawKey(String pem) {
    final body = pem
        .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    final List<int> der;
    try {
      der = base64.decode(body);
    } on FormatException {
      return null;
    }
    // SubjectPublicKeyInfo for Ed25519 (OID 1.3.101.112) is always this
    // 12-byte prefix followed by the key.
    const prefix = [48, 42, 48, 5, 6, 3, 43, 101, 112, 3, 33, 0];
    if (der.length != prefix.length + 32) return null;
    for (var i = 0; i < prefix.length; i++) {
      if (der[i] != prefix[i]) return null;
    }
    return der.sublist(prefix.length);
  }
}
