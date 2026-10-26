import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../data/desk/pictures.dart';
import '../data/settings.dart';
import 'llm_providers.dart';
import 'runtime/model_catalog.dart';

/// How pictures the human shares reach the companion.
enum SightMode {
  /// The chat model sees them itself: a server-hosted model, or a local one
  /// with its vision file (mmproj).
  native,

  /// Eyes, a small local vision model, describes each picture and the chat
  /// model reads the description.
  eyes,

  /// Nothing can see; the companion is told a picture was shared.
  none,
}

class Sight {
  /// How [s] sees pictures. [blind] holds the server-hosted models that
  /// turned a picture down, by [serverKey]; they get Eyes like a local
  /// model without vision.
  static SightMode modeFor(AppSettings s, {Set<String> blind = const {}}) {
    final native = switch (s.llmMode) {
      LlmMode.builtIn => ModelCatalog.mmprojFor(s) != null,
      LlmMode.external => !blind.contains(serverKey(s)),
    };
    if (native) return SightMode.native;
    return ModelCatalog.eyesInstalled(s) ? SightMode.eyes : SightMode.none;
  }

  /// Names the server-hosted model in [s], for [modeFor]'s blind list.
  static String serverKey(AppSettings s) => '${s.llmEndpoint}|${s.llmModel}';

  /// Whether pictures shared with [s] leave this computer: a server-hosted
  /// brain that isn't on this machine or the home network.
  static bool picturesLeave(AppSettings s) {
    if (s.llmMode != LlmMode.external) return false;
    if (LlmProvider.forEndpoint(s.llmEndpoint) != LlmProvider.custom) {
      return true;
    }
    final host = Uri.tryParse(s.llmEndpoint.trim())?.host.toLowerCase() ?? '';
    return !isLocalHost(host);
  }

  /// localhost, or a private network address.
  static bool isLocalHost(String host) {
    if (host.isEmpty || host == 'localhost' || host.endsWith('.local')) {
      return true;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168);
    }
    // fc00::/7, unique local addresses.
    return (b[0] & 0xFE) == 0xFC;
  }

  /// The longest side a picture is sent at. Vision models scale pictures
  /// down to about this anyway, and a smaller one reads faster, costs less
  /// on a paid API and keeps the request small.
  static const maxSide = 1280;

  /// A picture sent as is when it is a PNG or JPEG at most this big.
  static const _keepBytes = 1536 * 1024;

  /// [file] as a `data:` URL for an OpenAI-style `image_url` part: a PNG or
  /// JPEG, at most [maxSide] pixels a side. WebP is turned into JPEG, since
  /// llama.cpp can't read it. Done off the main thread.
  static Future<String> dataUrl(File file) async {
    final bytes = await file.readAsBytes();
    return Isolate.run(() => dataUrlOf(bytes));
  }

  static String dataUrlOf(Uint8List bytes) {
    final kind = Pictures.imageExtensionOf(bytes.take(12).toList());
    if (kind != 'webp' && bytes.length <= _keepBytes) {
      final decoded = kind == null ? null : img.findDecoderForData(bytes);
      final info = decoded?.startDecode(bytes);
      if (info != null && max(info.width, info.height) <= maxSide) {
        final mime = kind == 'png' ? 'image/png' : 'image/jpeg';
        return 'data:$mime;base64,${base64Encode(bytes)}';
      }
    }
    var image = img.decodeImage(bytes);
    if (image == null) throw const FormatException('Not a picture');
    if (max(image.width, image.height) > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide)
          : img.copyResize(image, height: maxSide);
    }
    final jpeg = img.encodeJpg(image, quality: 85);
    return 'data:image/jpeg;base64,${base64Encode(jpeg)}';
  }

  /// Picture bytes from the clipboard as a PNG, JPEG or WebP file's bytes:
  /// Windows can hand over a bitmap. Null when they aren't a picture.
  static Uint8List? normalizePasted(Uint8List bytes) {
    if (Pictures.imageExtensionOf(bytes.take(12).toList()) != null) {
      return bytes;
    }
    try {
      final image = img.decodeImage(bytes);
      return image == null ? null : img.encodePng(image);
    } on Object {
      return null; // the decoders throw on some junk
    }
  }
}
