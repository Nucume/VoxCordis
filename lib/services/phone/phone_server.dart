import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../logs/app_log.dart';
import 'phone_crypto.dart';
import 'phone_devices.dart';

/// Which addresses may talk to the phone server at all.
abstract final class PhoneNetwork {
  /// The home network (192.168.x.x, 10.x.x.x, 172.16-31.x.x), this
  /// computer itself, and with [tailscale] Tailscale's addresses
  /// (100.64.0.0/10).
  static bool allowed(InternetAddress a, {bool tailscale = false}) {
    if (a.isLoopback) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv6) {
      // An IPv4 address written the IPv6 way (::ffff:192.168.1.5).
      final mapped =
          b.length == 16 &&
          b.sublist(0, 10).every((x) => x == 0) &&
          b[10] == 0xff &&
          b[11] == 0xff;
      if (!mapped) return false;
      return allowed(
        InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
        tailscale: tailscale,
      );
    }
    if (b.length != 4) return false;
    if (b[0] == 10) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (tailscale && b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
    return false;
  }

  static bool isTailscale(InternetAddress a) {
    final b = a.rawAddress;
    return b.length == 4 && b[0] == 100 && b[1] >= 64 && b[1] <= 127;
  }

  /// Interfaces that are never the home network: containers, virtual
  /// machines, VPN tunnels.
  static final _virtual = RegExp(
    r'^(docker|br-|veth|virbr|vmnet|vboxnet|lxc|lxd|podman|cni|flannel|zt|tun|tap|wg|utun)',
    caseSensitive: false,
  );

  /// Where a phone can reach this computer, best first: the home network
  /// on a real network card, then Tailscale when [tailscale].
  static Future<List<String>> addresses({bool tailscale = false}) async {
    final List<NetworkInterface> list;
    try {
      list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } on Object {
      return const [];
    }
    final home = <String>[], virtual = <String>[], ts = <String>[];
    for (final i in list) {
      for (final a in i.addresses) {
        if (a.isLoopback) continue;
        if (isTailscale(a) || i.name.toLowerCase().startsWith('tailscale')) {
          if (isTailscale(a)) ts.add(a.address);
          continue;
        }
        if (!allowed(a)) continue;
        (_virtual.hasMatch(i.name) ? virtual : home).add(a.address);
      }
    }
    // 192.168 first: by far the most common home network.
    home.sort(
      (a, b) => (b.startsWith('192.168.') ? 1 : 0).compareTo(
        a.startsWith('192.168.') ? 1 : 0,
      ),
    );
    return [...home, ...virtual, if (tailscale) ...ts];
  }

  /// Whether Tailscale seems to run on this computer.
  static Future<bool> tailscaleRunning() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return list.any((i) => i.addresses.any(isTailscale));
    } on Object {
      return false;
    }
  }

  /// Whether [host] (a request's Host, without the port) names this
  /// computer rather than some website: an address, `localhost`, or a
  /// `.local` name. A page on another site can make a browser on the
  /// network send requests here (DNS rebinding), but never with this
  /// computer's address as the host.
  static bool hostIsLocal(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.local')) return true;
    if (h.endsWith('.ts.net')) return true;
    if (InternetAddress.tryParse(h.replaceAll(RegExp(r'^\[|\]$'), '')) !=
        null) {
      return true;
    }
    // This computer's own name, as some routers hand it out.
    final own = Platform.localHostname.toLowerCase();
    return h == own || h == '$own.lan' || h == '$own.home';
  }
}

/// One phone's connection, once it proved it has a key.
abstract class PhoneLink {
  /// The paired phone, or null while it is still being paired.
  PairedPhone? get phone;

  /// Sends [message] to the phone, sealed.
  Future<void> send(Map<String, Object?> message);
  Future<void> close();
}

/// What the server asks of the app: whether a new phone may pair, and
/// what to do with each message.
abstract class PhoneHandler {
  /// Asks on the computer whether the phone that calls itself [name] may
  /// use VoxCordis; the name it should have, or null for no. [check] is
  /// the code the phone shows when it paired without a QR code.
  Future<String?> allow(String name, String address, {String? check});

  /// A phone connected ([link]).
  void connected(PhoneLink link);
  void disconnected(PhoneLink link);

  /// Answers [request] (`op` and its arguments) from [link]; the reply's
  /// fields, or throws a [PhoneError] to say why not.
  Future<Map<String, Object?>> handle(
    PhoneLink link,
    String op,
    Map<String, Object?> request,
  );
}

/// A request a phone can't have, in words for the phone to show.
class PhoneError implements Exception {
  const PhoneError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The little web server phones use VoxCordis through: it serves the phone
/// page and, behind it, one sealed WebSocket per phone ([PhoneCrypto]).
///
/// Off unless Settings → Connections → Phone access is on. It listens on
/// every network card, but only answers the home network ([PhoneNetwork]),
/// and nothing past the page's own files without a paired phone's key.
class PhoneServer {
  PhoneServer({required this.devices, required this.handler, this.log});

  final PhoneDevices devices;
  final PhoneHandler handler;
  AppLog? log;

  HttpServer? _server;
  int? get port => _server?.port;
  bool get running => _server != null;
  bool tailscale = false;

  final _links = <_Link>{};

  /// Failed handshakes per address, so a code can't be guessed at.
  final _failures = <String, List<DateTime>>{};
  static const _maxFailures = 10;
  static const _failureWindow = Duration(minutes: 1);
  static const _pause = Duration(minutes: 5);

  /// The page's own files, from the app's assets.
  static const assets = 'assets/phone';
  static const _files = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/index.html': ('index.html', 'text/html; charset=utf-8'),
    '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
    '/app.css': ('app.css', 'text/css; charset=utf-8'),
    '/cipher.js': ('cipher.js', 'text/javascript; charset=utf-8'),
    '/manifest.webmanifest': (
      'manifest.webmanifest',
      'application/manifest+json',
    ),
    '/icon-192.png': ('icon-192.png', 'image/png'),
    '/icon-512.png': ('icon-512.png', 'image/png'),
    '/heart.svg': ('heart.svg', 'image/svg+xml'),
  };

  /// Reads an asset; replaceable for tests.
  Future<ByteData> Function(String key) loadAsset = rootBundle.load;

  Future<void> start(int port) async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    server.autoCompress = false;
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
    server.listen(
      _onRequest,
      onError: (Object e) => _note('Phone server: $e', error: true),
    );
    _note('Phone access is listening on port ${server.port}');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    for (final l in [..._links]) {
      await l.close();
    }
    _links.clear();
    await s?.close(force: true);
    if (s != null) _note('Phone access stopped');
  }

  /// Closes the connection of [phoneId], when unpaired.
  Future<void> drop(String phoneId) async {
    for (final l in [..._links]) {
      if (l.phone?.id == phoneId) await l.close();
    }
  }

  Iterable<PhoneLink> get links => _links;

  void _note(String m, {bool error = false}) =>
      log?.add(error ? LogKind.errors : LogKind.connections, m, error: error);

  bool _paused(String address) {
    final now = DateTime.now();
    final list = _failures[address];
    if (list == null) return false;
    list.removeWhere((t) => now.difference(t) > _pause);
    final recent = list.where((t) => now.difference(t) < _failureWindow);
    return list.length >= _maxFailures && recent.isNotEmpty ||
        list.length >= _maxFailures * 2;
  }

  void _failed(String address) {
    (_failures[address] ??= []).add(DateTime.now());
  }

  Future<void> _onRequest(HttpRequest req) async {
    final res = req.response;
    try {
      final remote = req.connectionInfo?.remoteAddress;
      if (remote == null ||
          !PhoneNetwork.allowed(remote, tailscale: tailscale)) {
        // Not the home network: as if nobody were here.
        await req.response.detachSocket().then((s) => s.destroy());
        return;
      }
      final host = (req.headers.host ?? '').toLowerCase();
      if (!PhoneNetwork.hostIsLocal(host)) {
        res.statusCode = HttpStatus.misdirectedRequest;
        await res.close();
        return;
      }
      res.headers
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('X-Frame-Options', 'DENY')
        ..set(
          'Content-Security-Policy',
          "default-src 'self'; img-src 'self' blob: data:; "
              "media-src 'self' blob:; "
              "connect-src 'self' ws: wss:; style-src 'self' 'unsafe-inline'; "
              "frame-ancestors 'none'",
        );
      final path = req.uri.path;
      if (path == '/ws') {
        await _upgrade(req, remote);
        return;
      }
      final file = _files[path];
      if (req.method != 'GET' || file == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final data = await loadAsset('$assets/${file.$1}');
      res.headers
        ..contentType = ContentType.parse(file.$2)
        ..set('Cache-Control', 'no-cache');
      res.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      await res.close();
    } on Object catch (e) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } on Object {
        // Already sent or gone.
      }
      _note('Phone server request failed: $e', error: true);
    }
  }

  Future<void> _upgrade(HttpRequest req, InternetAddress remote) async {
    // Only the page itself may open the connection, not some other site
    // open in a browser on the network.
    final origin = req.headers.value('origin');
    final host = req.headers.host ?? '';
    final hostPort = req.headers.port;
    final expected = {
      'http://$host:$hostPort',
      'https://$host:$hostPort',
      'http://$host',
      'https://$host',
    };
    if (origin == null ||
        !expected.contains(origin.toLowerCase()) ||
        !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    if (_paused(remote.address)) {
      req.response.statusCode = HttpStatus.tooManyRequests;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 30);
    final link = _Link(this, ws, remote.address);
    _links.add(link);
    link.run();
  }

  void _gone(_Link l) {
    _links.remove(l);
    if (l.ready) {
      final id = l.phone?.id;
      if (id != null && !_links.any((x) => x.phone?.id == id)) {
        devices.setConnected(id, false);
      }
      handler.disconnected(l);
    }
  }
}

class _Link implements PhoneLink {
  _Link(this.server, this.ws, this.address);

  final PhoneServer server;
  final WebSocket ws;
  final String address;

  @override
  PairedPhone? phone;
  SecretKey? _key;
  bool ready = false;
  bool _closed = false;
  int _inSeq = 0;
  int _outSeq = 0;

  /// Sealed sends go out in order, one after another.
  Future<void> _sending = Future.value();

  static const _handshakeTime = Duration(seconds: 20);
  bool _pairing = false;

  /// Pairing without a code, between the phone's promise and its key.
  ({
    List<int> commit,
    SimpleKeyPair key,
    List<int> phoneNonce,
    List<int> pcNonce,
  })?
  _near;

  /// The code both screens show, once paired without a QR code.
  String? _check;

  void run() {
    var hello = false;
    final timer = Timer(_handshakeTime, () {
      // Someone at the computer may still be deciding about a new phone.
      if (!ready && !_pairing) close();
    });
    ws.listen(
      (data) async {
        try {
          if (!hello) {
            hello = true;
            if (data is! String) throw const PhoneError('Say hello first.');
            await _hello(data);
            return;
          }
          if (_near != null) {
            if (data is! String) throw const PhoneError('Show your key.');
            await _reveal(data);
            return;
          }
          if (_key == null) return;
          if (data is! List<int>) throw const PhoneError('Sealed only.');
          final plain = await PhoneCrypto.open(
            _key!,
            data,
            aad: PhoneCrypto.toPc,
          );
          if (plain == null) {
            server._failed(address);
            await close();
            return;
          }
          final msg = jsonDecode(utf8.decode(plain));
          if (msg is! Map<String, Object?>) return;
          final seq = msg['s'];
          if (seq is! int || seq <= _inSeq) {
            await close();
            return;
          }
          _inSeq = seq;
          await _onMessage(msg);
        } on Object catch (e) {
          if (e is! PhoneError) server._note('Phone connection: $e');
          await close();
        }
      },
      onDone: () {
        timer.cancel();
        _closed = true;
        server._gone(this);
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// `{"hello":1,"device":id,"n":nonce}` or `{"hello":1,"pair":id,"n":…}`;
  /// answered with the computer's nonce, then everything is sealed.
  Future<void> _hello(String text) async {
    final j = jsonDecode(text);
    if (j is! Map) throw const PhoneError('Bad hello.');
    final phoneNonce = PhoneCrypto.decode('${j['n']}');
    if (phoneNonce.length != 24) throw const PhoneError('Bad nonce.');
    List<int>? secret;
    final deviceId = j['device'];
    final pairId = j['pair'];
    await server.devices.load();
    if (j['near'] == 1 && deviceId == null && pairId == null) {
      await _nearHello(j, phoneNonce);
      return;
    }
    if (deviceId is String) {
      final p = server.devices.byId(deviceId);
      if (p != null) {
        phone = p;
        secret = PhoneCrypto.decode(p.key);
      }
    } else if (pairId is String) {
      secret = server.devices.liveCode(pairId)?.secret;
    }
    if (secret == null) {
      server._failed(address);
      ws.add(jsonEncode({'error': deviceId is String ? 'unpaired' : 'code'}));
      await close();
      return;
    }
    final pcNonce = PhoneCrypto.randomBytes(24);
    _key = await PhoneCrypto.sessionKey(secret, phoneNonce, pcNonce);
    ws.add(jsonEncode({'n': PhoneCrypto.encode(pcNonce)}));
  }

  /// `{"hello":1,"near":1,"n":nonce,"c":sha256(phone key)}`: pairing
  /// without a QR code, while the computer is pairing (Settings → Phone
  /// access → Pair a phone). Answered with our nonce and public key.
  Future<void> _nearHello(Map<Object?, Object?> j, List<int> phoneNonce) async {
    final code = server.devices.code;
    if (code == null || !code.live) {
      ws.add(jsonEncode({'error': 'closed'}));
      await close();
      return;
    }
    final commit = PhoneCrypto.decode('${j['c']}');
    if (commit.length != 32) throw const PhoneError('Bad promise.');
    final key = await PhoneCrypto.newPairKey();
    final pcNonce = PhoneCrypto.randomBytes(24);
    _near = (
      commit: commit,
      key: key,
      phoneNonce: phoneNonce,
      pcNonce: pcNonce,
    );
    ws.add(
      jsonEncode({
        'n': PhoneCrypto.encode(pcNonce),
        'pk': PhoneCrypto.encode(await PhoneCrypto.publicOf(key)),
      }),
    );
  }

  /// `{"pk":phone key}`: must be the key the phone promised. Then both work
  /// out the same secret, and everything after is sealed with it.
  Future<void> _reveal(String text) async {
    final near = _near!;
    _near = null;
    final j = jsonDecode(text);
    final phonePublic = j is Map ? PhoneCrypto.decode('${j['pk']}') : null;
    if (phonePublic == null ||
        !_same(PhoneCrypto.commit(phonePublic), near.commit)) {
      server._failed(address);
      await close();
      return;
    }
    final pcPublic = await PhoneCrypto.publicOf(near.key);
    final secret = await PhoneCrypto.pairSecret(
      near.key,
      phonePublic,
      pcPublic,
    );
    if (secret == null) {
      server._failed(address);
      await close();
      return;
    }
    _check = PhoneCrypto.checkCode(
      phonePublic,
      pcPublic,
      near.phoneNonce,
      near.pcNonce,
    );
    _key = await PhoneCrypto.sessionKey(secret, near.phoneNonce, near.pcNonce);
    ws.add(jsonEncode({'ok': 1}));
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  Future<void> _onMessage(Map<String, Object?> msg) async {
    final id = msg['id'];
    final op = '${msg['op']}';
    if (!ready) {
      // The first sealed message: pairing, or a paired phone coming back.
      if (op != 'hello') throw const PhoneError('Hello first.');
      if (phone == null) {
        await _pair(id, msg);
        return;
      }
      ready = true;
      server.devices.setConnected(phone!.id, true);
      unawaited(server.devices.seen(phone!.id));
      server.handler.connected(this);
      await _answer(id, op, msg);
      return;
    }
    await _answer(id, op, msg);
  }

  Future<void> _pair(Object? id, Map<String, Object?> msg) async {
    final code = server.devices.code;
    if (code == null || !code.live) {
      await send({
        're': id,
        'error': 'This code has run out. Make a new one on your PC.',
      });
      await close();
      return;
    }
    // One phone per code, even while the computer asks.
    code.used = true;
    final asked = '${msg['name'] ?? ''}'.trim();
    _pairing = true;
    final name = await server.handler
        .allow(asked.isEmpty ? 'A phone' : asked, address, check: _check)
        .timeout(const Duration(minutes: 3), onTimeout: () => null);
    _pairing = false;
    if (_closed) {
      server.devices.dropCode();
      return;
    }
    server.devices.dropCode();
    if (name == null) {
      await send({'re': id, 'error': 'Your PC declined this request.'});
      await close();
      return;
    }
    final p = phone = await server.devices.add(name);
    ready = true;
    server.devices.setConnected(p.id, true);
    server.handler.connected(this);
    final reply = await server.handler.handle(this, 'hello', msg);
    await send({
      're': id,
      'paired': {'id': p.id, 'key': p.key, 'name': p.name},
      ...reply,
    });
  }

  Future<void> _answer(Object? id, String op, Map<String, Object?> msg) async {
    try {
      final reply = await server.handler.handle(this, op, msg);
      await send({'re': id, ...reply});
    } on PhoneError catch (e) {
      await send({'re': id, 'error': e.message});
    } on Object catch (e) {
      server._note('Phone request $op failed: $e', error: true);
      await send({'re': id, 'error': 'Something went wrong on your PC: $e'});
    }
  }

  @override
  Future<void> send(Map<String, Object?> message) {
    final key = _key;
    if (key == null || _closed) return Future.value();
    final next = _sending.then((_) async {
      if (_closed) return;
      final plain = utf8.encode(jsonEncode({...message, 's': ++_outSeq}));
      final sealed = await PhoneCrypto.seal(
        key,
        plain,
        aad: PhoneCrypto.toPhone,
      );
      if (!_closed) ws.add(sealed);
    });
    _sending = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await ws.close(WebSocketStatus.normalClosure);
    } on Object {
      // Already gone.
    }
  }
}

/// Keeps work off the window's thread: big pictures are made small for the
/// phone in the background.
Future<T> phoneCompute<T, A>(FutureOr<T> Function(A) f, A arg) =>
    compute(f, arg);
