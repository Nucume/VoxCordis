import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

/// What keeps a phone's messages private on the home network.
///
/// Phones talk to VoxCordis over plain http, where browsers keep their own
/// encryption (WebCrypto) switched off, so the phone page carries a small
/// cipher library and both ends use XChaCha20-Poly1305 with a key only the
/// two of them know:
///
/// - pairing: the 32 random bytes in the QR code, after the `#` of its
///   link, which browsers never send over the network;
///   or, pairing without a camera, a secret the phone and computer work
///   out together over X25519 ([pairSecret]), checked by eye: both screens
///   show the same five signs ([checkCode]) only when nobody is in between;
/// - after that: a key of the phone's own, handed over once paired.
///
/// Each connection mixes fresh random bytes from both ends into that key
/// ([sessionKey]), so a message recorded on the network is useless in any
/// other connection, and every message carries a count that only goes up,
/// so none can be played twice in the same one.
abstract final class PhoneCrypto {
  static final _aead = Xchacha20.poly1305Aead();
  static final _random = Random.secure();

  static const keyBytes = 32;
  static const nonceBytes = 24;
  static const macBytes = 16;
  static const _info = 'voxcordis phone v1';
  static const _pairInfo = 'voxcordis pair v1';
  static const _checkInfo = 'voxcordis check v1';
  static final _x25519 = X25519();

  /// What each side adds to its messages, so one can't be sent back to
  /// where it came from.
  static final toPhone = utf8.encode('to phone');
  static final toPc = utf8.encode('to pc');

  static Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  /// base64url without padding, as the page writes it.
  static String encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List decode(String text) {
    final pad = (4 - text.length % 4) % 4;
    return base64Url.decode(text + '=' * pad);
  }

  /// The key for one connection: [secret] (the pairing code's or the
  /// phone's own) mixed with both ends' fresh bytes.
  static Future<SecretKey> sessionKey(
    List<int> secret,
    List<int> phoneNonce,
    List<int> pcNonce,
  ) => Hkdf(hmac: Hmac.sha256(), outputLength: keyBytes).deriveKey(
    secretKey: SecretKey(secret),
    nonce: [...phoneNonce, ...pcNonce],
    info: utf8.encode(_info),
  );

  /// Nonce, then the sealed text and its tag: what the page's
  /// `xchacha20poly1305(key, nonce, aad).encrypt` gives, after its nonce.
  ///
  /// Anything from [backgroundFrom] bytes up (a picture) is sealed on a
  /// background thread: the cipher is plain Dart, and a few megabytes of
  /// it would hold up the window on the computer while a phone looks at
  /// pictures.
  static Future<Uint8List> seal(
    SecretKey key,
    List<int> plain, {
    required List<int> aad,
  }) async {
    if (plain.length < backgroundFrom) return _seal(key, plain, aad);
    final bytes = Uint8List.fromList(await key.extractBytes());
    final text = plain is Uint8List ? plain : Uint8List.fromList(plain);
    final extra = Uint8List.fromList(aad);
    return Isolate.run(() => _seal(SecretKey(bytes), text, extra));
  }

  static const backgroundFrom = 256 * 1024;

  static Future<Uint8List> _seal(
    SecretKey key,
    List<int> plain,
    List<int> aad,
  ) async {
    final nonce = randomBytes(nonceBytes);
    final box = await _aead.encrypt(
      plain,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final text = box.cipherText, mac = box.mac.bytes;
    // Laid out in place: spread into a list first, a picture took several
    // times its size on the way.
    return Uint8List(nonce.length + text.length + mac.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + text.length, text)
      ..setRange(
        nonce.length + text.length,
        nonce.length + text.length + mac.length,
        mac,
      );
  }

  /// The text sealed in [frame], or null when it wasn't sealed with [key]
  /// for [aad] (or was changed on the way).
  static Future<Uint8List?> open(
    SecretKey key,
    List<int> frame, {
    required List<int> aad,
  }) async {
    if (frame.length < nonceBytes + macBytes) return null;
    final nonce = frame.sublist(0, nonceBytes);
    final body = frame.sublist(nonceBytes, frame.length - macBytes);
    final mac = Mac(frame.sublist(frame.length - macBytes));
    try {
      final plain = await _aead.decrypt(
        SecretBox(body, nonce: nonce, mac: mac),
        secretKey: key,
        aad: aad,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  /// A fresh X25519 key pair for pairing without a code.
  static Future<SimpleKeyPair> newPairKey() => _x25519.newKeyPair();

  static Future<List<int>> publicOf(SimpleKeyPair key) async =>
      (await key.extractPublicKey()).bytes;

  /// The phone's promise of its public key, sent before it sees ours.
  static List<int> commit(List<int> publicKey) =>
      hash.sha256.convert(publicKey).bytes;

  /// The pairing secret from X25519 between [mine] and [phonePublic]: what
  /// the page's `hkdf(sha256, x25519(...), phone‖pc, "voxcordis pair v1")`
  /// gives. Null for a key that would give a known secret.
  static Future<List<int>?> pairSecret(
    SimpleKeyPair mine,
    List<int> phonePublic,
    List<int> pcPublic,
  ) async {
    if (phonePublic.length != 32) return null;
    final shared = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(phonePublic, type: KeyPairType.x25519),
    );
    final bytes = await shared.extractBytes();
    if (bytes.every((b) => b == 0)) return null;
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: keyBytes)
        .deriveKey(
          secretKey: SecretKey(bytes),
          nonce: [...phonePublic, ...pcPublic],
          info: utf8.encode(_pairInfo),
        );
    return key.extractBytes();
  }

  /// Signs that can't be mistaken for each other: no 0/O or 1/I.
  static const _signs = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// The five capitals and digits both screens show while pairing without
  /// a code: 25 bits of a hash of everything both sides said, so someone
  /// in between has one chance in 33 million to make them match.
  static String checkCode(
    List<int> phonePublic,
    List<int> pcPublic,
    List<int> phoneNonce,
    List<int> pcNonce,
  ) {
    final h = hash.sha256.convert([
      ...utf8.encode(_checkInfo),
      ...phonePublic,
      ...pcPublic,
      ...phoneNonce,
      ...pcNonce,
    ]).bytes;
    final n = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
    return [
      for (var i = 0; i < 5; i++) _signs[(n >> (27 - 5 * i)) & 31],
    ].join();
  }
}
