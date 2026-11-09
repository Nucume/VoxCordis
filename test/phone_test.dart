import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:companion/services/phone/phone_crypto.dart';
import 'package:companion/services/phone/phone_devices.dart';
import 'package:companion/services/phone/phone_firewall.dart';
import 'package:companion/services/phone/phone_server.dart';
import 'package:companion/services/secret_store.dart';

/// Answers like the app would, without the app.
class _Handler implements PhoneHandler {
  String? answer = 'Test phone';
  final asked = <String>[];
  final checks = <String?>[];
  final links = <PhoneLink>[];

  @override
  Future<String?> allow(String name, String address, {String? check}) async {
    asked.add(name);
    checks.add(check);
    return answer;
  }

  @override
  void connected(PhoneLink link) => links.add(link);

  @override
  void disconnected(PhoneLink link) => links.remove(link);

  @override
  Future<Map<String, Object?>> handle(
    PhoneLink link,
    String op,
    Map<String, Object?> request,
  ) async {
    if (op == 'hello') return {'companion': 'Voxette'};
    if (op == 'echo') return {'said': request['text']};
    throw PhoneError('Unknown request $op.');
  }
}

/// A phone, written the way the page talks.
class _Phone {
  _Phone(this.ws);

  final WebSocket ws;
  late final StreamIterator<Object?> _in = StreamIterator(ws);
  SecretKey? key;
  int _seq = 0;
  int _inSeq = 0;

  static Future<_Phone> connect(int port, {String? origin}) async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {'Origin': origin ?? 'http://127.0.0.1:$port'},
    );
    return _Phone(ws);
  }

  /// The plain hello; the PC's reply.
  Future<Map<String, Object?>> hello(
    List<int> secret, {
    String? device,
    String? pair,
  }) async {
    final nonce = PhoneCrypto.randomBytes(24);
    ws.add(
      jsonEncode({
        'hello': 1,
        'device': ?device,
        'pair': ?pair,
        'n': PhoneCrypto.encode(nonce),
      }),
    );
    final reply = jsonDecode(await _next() as String) as Map<String, Object?>;
    if (reply['n'] case final String n) {
      key = await PhoneCrypto.sessionKey(secret, nonce, PhoneCrypto.decode(n));
    }
    return reply;
  }

  /// Pairing without a code, as the page's Pair with my PC does; the code
  /// the phone shows, or the PC's error.
  Future<String> near({bool cheat = false}) async {
    final x = X25519();
    final mine = await x.newKeyPair();
    final myPublic = (await mine.extractPublicKey()).bytes;
    final nonce = PhoneCrypto.randomBytes(24);
    ws.add(
      jsonEncode({
        'hello': 1,
        'near': 1,
        'n': PhoneCrypto.encode(nonce),
        'c': PhoneCrypto.encode(PhoneCrypto.commit(myPublic)),
      }),
    );
    final first = jsonDecode(await _next() as String) as Map<String, Object?>;
    if (first['error'] case final String error) return error;
    final pcNonce = PhoneCrypto.decode(first['n']! as String);
    final pcPublic = PhoneCrypto.decode(first['pk']! as String);
    // Someone in between, showing a key other than the one promised.
    final shown = cheat
        ? (await (await x.newKeyPair()).extractPublicKey()).bytes
        : myPublic;
    ws.add(jsonEncode({'pk': PhoneCrypto.encode(shown)}));
    final ok = jsonDecode(await _next() as String) as Map<String, Object?>;
    expect(ok['ok'], 1);
    final shared = await (await x.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(pcPublic, type: KeyPairType.x25519),
    )).extractBytes();
    final secret =
        await (await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
          secretKey: SecretKey(shared),
          nonce: [...myPublic, ...pcPublic],
          info: utf8.encode('voxcordis pair v1'),
        )).extractBytes();
    key = await PhoneCrypto.sessionKey(secret, nonce, pcNonce);
    return PhoneCrypto.checkCode(myPublic, pcPublic, nonce, pcNonce);
  }

  Future<Object?> _next() async {
    if (!await _in.moveNext().timeout(const Duration(seconds: 5))) {
      throw StateError('closed');
    }
    return _in.current;
  }

  Future<void> send(Map<String, Object?> m) async {
    final frame = await PhoneCrypto.seal(
      key!,
      utf8.encode(jsonEncode({'s': ++_seq, ...m})),
      aad: PhoneCrypto.toPc,
    );
    ws.add(frame);
  }

  Future<Map<String, Object?>> receive() async {
    final data = await _next();
    final plain = await PhoneCrypto.open(
      key!,
      data! as List<int>,
      aad: PhoneCrypto.toPhone,
    );
    final m = jsonDecode(utf8.decode(plain!)) as Map<String, Object?>;
    final s = m['s']! as int;
    expect(s, greaterThan(_inSeq));
    _inSeq = s;
    return m;
  }

  /// Whether the PC hung up.
  Future<bool> closed() async {
    try {
      await _next();
      return false;
    } on StateError {
      return true;
    }
  }
}

void main() {
  group('PhoneCrypto', () {
    test('seals and opens, and nothing else opens', () async {
      final key = await PhoneCrypto.sessionKey(
        PhoneCrypto.randomBytes(32),
        PhoneCrypto.randomBytes(24),
        PhoneCrypto.randomBytes(24),
      );
      final frame = await PhoneCrypto.seal(
        key,
        utf8.encode('hello'),
        aad: PhoneCrypto.toPhone,
      );
      expect(frame.length, 24 + 5 + 16);
      final plain = await PhoneCrypto.open(
        key,
        frame,
        aad: PhoneCrypto.toPhone,
      );
      expect(utf8.decode(plain!), 'hello');
      // Sent back the other way, or changed on the way: refused.
      expect(await PhoneCrypto.open(key, frame, aad: PhoneCrypto.toPc), isNull);
      final changed = Uint8List.fromList(frame)..[30] ^= 1;
      expect(
        await PhoneCrypto.open(key, changed, aad: PhoneCrypto.toPhone),
        isNull,
      );
      final other = await PhoneCrypto.sessionKey(
        PhoneCrypto.randomBytes(32),
        PhoneCrypto.randomBytes(24),
        PhoneCrypto.randomBytes(24),
      );
      expect(
        await PhoneCrypto.open(other, frame, aad: PhoneCrypto.toPhone),
        isNull,
      );
    });

    test('a picture-sized message is sealed in the background, and opens '
        'the same', () async {
      final key = await PhoneCrypto.sessionKey(
        PhoneCrypto.randomBytes(32),
        PhoneCrypto.randomBytes(24),
        PhoneCrypto.randomBytes(24),
      );
      final big = Uint8List(PhoneCrypto.backgroundFrom + 12345);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 31 + 7) & 0xFF;
      }
      final frame = await PhoneCrypto.seal(key, big, aad: PhoneCrypto.toPhone);
      expect(frame.length, 24 + big.length + 16);
      final plain = await PhoneCrypto.open(
        key,
        frame,
        aad: PhoneCrypto.toPhone,
      );
      expect(plain, big);
      expect(await PhoneCrypto.open(key, frame, aad: PhoneCrypto.toPc), isNull);
    });

    test('the session key is HKDF-SHA256 over both nonces', () async {
      // Same inputs as the page's hkdf(sha256, secret, phone‖pc, info, 32).
      final secret = List.generate(32, (i) => i);
      final phone = List.generate(24, (i) => 100 + i);
      final pc = List.generate(24, (i) => 200 + i);
      final a = await (await PhoneCrypto.sessionKey(
        secret,
        phone,
        pc,
      )).extractBytes();
      final b = await (await PhoneCrypto.sessionKey(
        secret,
        pc,
        phone,
      )).extractBytes();
      expect(a, hasLength(32));
      expect(a, isNot(b));
      // What the page's cipher.js (@noble) makes of the same, and a
      // message it sealed with that key: the two ends agree.
      expect(
        PhoneCrypto.encode(a),
        'n7McVnR5cA3mDDN-Ir1D9hKcXBMDF-MjGuQPtDhk2PQ',
      );
      final fromPage = PhoneCrypto.decode(
        'AAMGCQwPEhUYGx4hJCcqLTAzNjk8P0JFmxyJMIokjLCudppKvl57-3yDlDRg330247qeIrwMoi-rO6hW',
      );
      final plain = await PhoneCrypto.open(
        SecretKey(a),
        fromPage,
        aad: PhoneCrypto.toPc,
      );
      expect(utf8.decode(plain!), '{"s":1,"op":"hello"}');
    });

    test('pairing without a code agrees with the page', () async {
      // What the page's cipher.js (@noble/curves x25519) and checkNumber
      // make of these keys and nonces.
      final phonePublic = PhoneCrypto.decode(
        'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw',
      );
      final pcKey = await X25519().newKeyPairFromSeed(
        List.generate(32, (i) => 64 + i),
      );
      final pcPublic = await PhoneCrypto.publicOf(pcKey);
      expect(
        PhoneCrypto.encode(pcPublic),
        'eaYx7t4b-cmPEgMs3q3Q56B5OY_HhriMyEbsia-FpRo',
      );
      expect(
        PhoneCrypto.encode(PhoneCrypto.commit(phonePublic)),
        'qqj_9wO1CyKX9PbhNQj3JCDZb9Aeu4TLB0RJyq72QEE',
      );
      final secret = await PhoneCrypto.pairSecret(pcKey, phonePublic, pcPublic);
      expect(
        PhoneCrypto.encode(secret!),
        'n8EiJcAf-6-4EQb7Hw430iqekPrT9XLNQPhOqPXKPlY',
      );
      expect(
        PhoneCrypto.checkCode(
          phonePublic,
          pcPublic,
          List.generate(24, (i) => 100 + i),
          List.generate(24, (i) => 200 + i),
        ),
        'Y5ARL',
      );
      // A key that gives a known secret is turned away.
      expect(
        await PhoneCrypto.pairSecret(pcKey, List.filled(32, 0), pcPublic),
        isNull,
      );
    });

    test('base64url round trip without padding', () {
      for (var n = 0; n < 40; n++) {
        final bytes = PhoneCrypto.randomBytes(n);
        final text = PhoneCrypto.encode(bytes);
        expect(text.contains('='), isFalse);
        expect(PhoneCrypto.decode(text), bytes);
      }
    });
  });

  group('PhoneNetwork', () {
    InternetAddress ip(String s) => InternetAddress(s);

    test('only the home network gets in', () {
      expect(PhoneNetwork.allowed(ip('192.168.1.20')), isTrue);
      expect(PhoneNetwork.allowed(ip('10.0.0.7')), isTrue);
      expect(PhoneNetwork.allowed(ip('172.20.1.1')), isTrue);
      expect(PhoneNetwork.allowed(ip('127.0.0.1')), isTrue);
      expect(PhoneNetwork.allowed(ip('::ffff:192.168.0.5')), isTrue);
      expect(PhoneNetwork.allowed(ip('8.8.8.8')), isFalse);
      expect(PhoneNetwork.allowed(ip('172.32.0.1')), isFalse);
      expect(PhoneNetwork.allowed(ip('2001:db8::1')), isFalse);
      expect(PhoneNetwork.allowed(ip('100.100.1.1')), isFalse);
      expect(PhoneNetwork.allowed(ip('100.100.1.1'), tailscale: true), isTrue);
    });

    test('only this computer\'s names are a host', () {
      expect(PhoneNetwork.hostIsLocal('192.168.1.20'), isTrue);
      expect(PhoneNetwork.hostIsLocal('localhost'), isTrue);
      expect(PhoneNetwork.hostIsLocal('desk.local'), isTrue);
      expect(PhoneNetwork.hostIsLocal('desk.tail1234.ts.net'), isTrue);
      expect(PhoneNetwork.hostIsLocal('evil.example.com'), isFalse);
    });
  });

  group('PhoneFirewall', () {
    final calls = <List<String>>[];
    var exitCode = 0;
    var firewalld = false;
    late Directory dir;

    setUp(() async {
      calls.clear();
      exitCode = 0;
      firewalld = false;
      dir = await Directory.systemTemp.createTemp('firewall_test');
      PhoneFirewall.ufwConfig = '${dir.path}/ufw.conf';
      PhoneFirewall.run = (exe, args) async {
        calls.add([exe, ...args]);
        if (exe == 'firewall-cmd') {
          if (!firewalld) throw const ProcessException('firewall-cmd', []);
          if (args.first == '--state') {
            return ProcessResult(0, 0, 'running\n', '');
          }
          return ProcessResult(0, 0, '8080/tcp 1025-65535/udp', '');
        }
        return ProcessResult(0, exitCode, '', exitCode == 0 ? '' : 'nope');
      };
    });

    tearDown(() async {
      PhoneFirewall.run = Process.run;
      await dir.delete(recursive: true);
    });

    test('reads which ports firewalld lets in', () {
      expect(
        PhoneFirewall.portListed('8080/tcp 1025-65535/tcp', 47800),
        isTrue,
      );
      expect(PhoneFirewall.portListed('47800/tcp', 47800), isTrue);
      expect(PhoneFirewall.portListed('1025-65535/udp 22/tcp', 47800), isFalse);
      expect(PhoneFirewall.portListed('', 47800), isFalse);
    });

    test('finds ufw and firewalld', () async {
      expect((await PhoneFirewall.check(47800)).kind, FirewallKind.none);
      await File(PhoneFirewall.ufwConfig).writeAsString('ENABLED=yes\n');
      final ufw = await PhoneFirewall.check(47800);
      expect(ufw.kind, FirewallKind.ufw);
      expect(ufw.open, isNull);
      firewalld = true;
      final fw = await PhoneFirewall.check(47800);
      expect(fw.kind, FirewallKind.firewalld);
      expect(fw.open, isFalse);
    });

    test('opens ufw for the home network only, with one password', () async {
      expect(
        await PhoneFirewall.change(FirewallKind.ufw, 47800, tailscale: true),
        isNull,
      );
      expect(calls, hasLength(1));
      expect(calls.single.take(3), ['pkexec', '/bin/sh', '-c']);
      final script = calls.single.last;
      for (final net in [
        '192.168.0.0/16',
        '10.0.0.0/8',
        '172.16.0.0/12',
        '100.64.0.0/10',
      ]) {
        expect(
          script,
          contains('ufw allow from $net to any port 47800 proto tcp'),
        );
      }
      expect(script, isNot(contains('allow 47800')));
      // The password prompt closed: nothing changed, and it says so.
      exitCode = 126;
      expect(
        await PhoneFirewall.change(FirewallKind.ufw, 47800),
        contains('password'),
      );
    });

    test('opens firewalld now and after a restart', () {
      expect(PhoneFirewall.commands(FirewallKind.firewalld, 47800), [
        'firewall-cmd --add-port=47800/tcp',
        'firewall-cmd --permanent --add-port=47800/tcp',
      ]);
      expect(
        PhoneFirewall.commands(FirewallKind.firewalld, 47800, close: true),
        [
          'firewall-cmd --remove-port=47800/tcp',
          'firewall-cmd --permanent --remove-port=47800/tcp',
        ],
      );
    });
  });

  group('PhoneServer', () {
    late Directory dir;
    late PhoneDevices devices;
    late _Handler handler;
    late PhoneServer server;
    late int port;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('phone_test');
      devices = PhoneDevices(SecretStore(dir, system: false));
      handler = _Handler();
      server = PhoneServer(devices: devices, handler: handler)
        ..loadAsset = (key) async {
          final bytes = await File(key).readAsBytes();
          return ByteData.sublistView(bytes);
        };
      devices.onRemoved = (id) => server.drop(id);
      await server.start(0);
      port = server.port!;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('serves the page with its guards', () async {
      final client = HttpClient();
      final req = await client.get('127.0.0.1', port, '/');
      final res = await req.close();
      final body = await utf8.decodeStream(res);
      expect(res.statusCode, 200);
      expect(body, contains('app.js'));
      expect(res.headers.value('content-security-policy'), contains("'self'"));
      final js = await (await client.get('127.0.0.1', port, '/app.js')).close();
      expect(js.statusCode, 200);
      await js.drain<void>();
      final other = await (await client.get(
        '127.0.0.1',
        port,
        '/../pubspec.yaml',
      )).close();
      expect(other.statusCode, 404);
      await other.drain<void>();
      // A website pointing its name at this computer gets nothing.
      final rebound = await client.get('127.0.0.1', port, '/');
      rebound.headers.host = 'evil.example.com';
      final r2 = await rebound.close();
      expect(r2.statusCode, HttpStatus.misdirectedRequest);
      await r2.drain<void>();
      client.close();
    });

    test('pairs with a code once, then knows the phone', () async {
      final code = devices.newCode();
      final phone = await _Phone.connect(port);
      expect((await phone.hello(code.secret, pair: code.id))['n'], isNotNull);
      await phone.send({'id': 1, 'op': 'hello', 'name': 'Pixel'});
      final reply = await phone.receive();
      expect(reply['re'], 1);
      expect(reply['companion'], 'Voxette');
      final paired = reply['paired']! as Map<String, Object?>;
      expect(paired['name'], 'Test phone');
      expect(handler.asked, ['Pixel']);
      expect(devices.phones, hasLength(1));
      expect(devices.connected, contains(paired['id']));
      await phone.send({'id': 2, 'op': 'echo', 'text': 'hi'});
      expect((await phone.receive())['said'], 'hi');
      await phone.send({'id': 3, 'op': 'nope'});
      expect((await phone.receive())['error'], 'Unknown request nope.');
      await phone.ws.close();

      // The code is spent.
      final again = await _Phone.connect(port);
      expect((await again.hello(code.secret, pair: code.id))['error'], 'code');

      // The phone's own key works from now on.
      final back = await _Phone.connect(port);
      final key = PhoneCrypto.decode(paired['key']! as String);
      expect(
        (await back.hello(key, device: paired['id']! as String))['n'],
        isNotNull,
      );
      await back.send({'id': 1, 'op': 'hello'});
      expect((await back.receive())['companion'], 'Voxette');

      // Removed on the PC: cut off, and not let back in.
      await devices.remove(paired['id']! as String);
      expect(await back.closed(), isTrue);
      final gone = await _Phone.connect(port);
      expect(
        (await gone.hello(key, device: paired['id']! as String))['error'],
        'unpaired',
      );
    });

    test('pairs without a code while pairing is open', () async {
      // Not pairing: turned away.
      final early = await _Phone.connect(port);
      expect(await early.near(), 'closed');

      devices.newCode();
      final phone = await _Phone.connect(port);
      final shows = await phone.near();
      expect(shows, matches(RegExp(r'^[A-HJ-NP-Z2-9]{5}$')));
      await phone.send({'id': 1, 'op': 'hello', 'name': 'iPhone'});
      final reply = await phone.receive();
      expect(reply['paired'], isNotNull);
      // The PC asked with the same code the phone shows.
      expect(handler.checks, [shows]);
      expect(devices.phones, hasLength(1));
      await phone.ws.close();

      // One phone per opening.
      final second = await _Phone.connect(port);
      expect(await second.near(), 'closed');
    });

    test('a phone showing another key than it promised is cut off', () async {
      devices.newCode();
      final phone = await _Phone.connect(port);
      await expectLater(phone.near(cheat: true), throwsStateError);
      expect(handler.asked, isEmpty);
    });

    test('a no on the PC pairs nothing', () async {
      handler.answer = null;
      final code = devices.newCode();
      final phone = await _Phone.connect(port);
      await phone.hello(code.secret, pair: code.id);
      await phone.send({'id': 1, 'op': 'hello'});
      expect(
        (await phone.receive())['error'],
        'Your PC declined this request.',
      );
      expect(devices.phones, isEmpty);
    });

    test('a wrong key, a replay or another site is cut off', () async {
      final code = devices.newCode();
      // The right code id with the wrong secret: the first sealed message
      // doesn't open.
      final wrong = await _Phone.connect(port);
      await wrong.hello(PhoneCrypto.randomBytes(32), pair: code.id);
      await wrong.send({'id': 1, 'op': 'hello'});
      expect(await wrong.closed(), isTrue);
      expect(devices.phones, isEmpty);

      final phone = await _Phone.connect(port);
      await phone.hello(code.secret, pair: code.id);
      await phone.send({'id': 1, 'op': 'hello'});
      await phone.receive();
      // The same count again.
      phone._seq = 0;
      await phone.send({'id': 2, 'op': 'echo', 'text': 'again'});
      expect(await phone.closed(), isTrue);

      await expectLater(
        _Phone.connect(port, origin: 'http://evil.example.com'),
        throwsA(isA<WebSocketException>()),
      );
    });
  });
}
