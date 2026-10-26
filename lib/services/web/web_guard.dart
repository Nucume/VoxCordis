import 'dart:io';

/// Decides which addresses the companion may visit on the web.
///
/// Only http and https, never this computer or the home network: a page
/// the companion reads could tell it to "check http://192.168.1.1/admin",
/// and the router would answer as if the human asked. Sites the human
/// listed in Settings → Internet are refused too, with their subdomains.
class WebGuard {
  const WebGuard({this.blocked = const []});

  /// Sites the human never wants visited, e.g. `facebook.com`.
  final List<String> blocked;

  /// Why [url] may not be visited, or null when it may.
  String? refuse(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) {
      return 'Only http and https addresses can be visited.';
    }
    final host = url.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty) return 'That address has no site in it.';
    if (isLocal(host)) {
      return 'Addresses on this computer or the home network are off limits.';
    }
    for (final site in blocked) {
      final b = normalizeSite(site);
      if (b.isNotEmpty && (host == b || host.endsWith('.$b'))) {
        return 'Your human asked you never to visit $b.';
      }
    }
    return null;
  }

  /// `https://www.Example.com/path` → `example.com`, as typed in Settings.
  static String normalizeSite(String site) {
    var s = site.trim().toLowerCase();
    s = s.replaceFirst(RegExp(r'^[a-z]+://'), '');
    s = s.split(RegExp(r'[/?#]')).first;
    s = s.replaceFirst(RegExp(r':\d+$'), '');
    return s.replaceFirst(RegExp(r'^www\.'), '');
  }

  /// Whether [host] is this computer or a private network: by name, or as
  /// an IPv4 or IPv6 address in a loopback, private, link-local or
  /// carrier-grade range.
  static bool isLocal(String host) {
    final h = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    if (h == 'localhost' ||
        h.endsWith('.localhost') ||
        h.endsWith('.local') ||
        h.endsWith('.lan') ||
        h.endsWith('.internal') ||
        h.endsWith('.home.arpa') ||
        !h.contains('.') && !h.contains(':')) {
      return true;
    }
    final ip = InternetAddress.tryParse(h);
    if (ip == null) return false;
    return isLocalAddress(ip);
  }

  static bool isLocalAddress(InternetAddress ip) {
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168) ||
          b[0] >= 224;
    }
    // IPv4 written as IPv6 (::ffff:10.0.0.1).
    if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 255 && b[11] == 255) {
      return isLocalAddress(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    return ip.isLoopback ||
        b.every((x) => x == 0) ||
        (b[0] & 0xfe) == 0xfc || // unique local fc00::/7
        (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || // link-local fe80::/10
        b[0] == 0xff; // multicast
  }

  /// Whether every address [host] resolves to is out on the internet, so a
  /// public-looking name can't lead to the home network.
  static Future<bool> resolvesPublic(String host) async {
    if (InternetAddress.tryParse(host) != null) return !isLocal(host);
    try {
      final addresses = await InternetAddress.lookup(host);
      return addresses.isNotEmpty && !addresses.any(isLocalAddress);
    } on SocketException {
      // Not found: the request fails on its own.
      return true;
    }
  }
}
