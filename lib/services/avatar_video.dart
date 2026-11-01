import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Video portraits: a short clip (`avatar.mp4` or `.webm`) next to the
/// companion's still picture, played muted and looping. Soulkyn gives some
/// characters one. Needs libmpv: bundled on Windows, the system's on Linux.
/// Without it the still picture shows, as before.
class AvatarVideo {
  /// Whether libmpv and the video plugin were both found, so a video can
  /// play inside the app.
  static bool get available => _available;
  static bool _available = false;

  /// Why videos can't play here, for Settings → Logs. Null when they can.
  static String? get unavailableReason => _reason;
  static String? _reason;

  /// The video plugin's channel. On Linux the runner loads the plugin at
  /// startup (linux/runner/webview_loader.cc) and leaves it out when its
  /// library won't load, e.g. when libmpv is missing or a different version.
  @visibleForTesting
  static const channel = MethodChannel('com.alexmercerind/media_kit_video');

  /// Called once at startup.
  static Future<void> init() async {
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      _reason = 'Videos play outside the app: libmpv was not found ($e).';
      debugPrint(_reason);
      return;
    }
    _available = await pluginLoaded();
    if (!_available) {
      _reason =
          'Videos play outside the app: the video player plugin did not '
          'load. On Linux, install libmpv (libmpv2 or mpv-libs).';
      debugPrint(_reason);
    }
  }

  /// Asks the plugin to drop a video output that never existed, which it
  /// answers when it is there. Without it, every [VideoController] fails
  /// with a MissingPluginException.
  @visibleForTesting
  static Future<bool> pluginLoaded() async {
    try {
      await channel
          .invokeMethod<void>('VideoOutputManager.Dispose', {'handle': '0'})
          .timeout(const Duration(seconds: 5));
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      // It answered, just not as expected: it is there.
      debugPrint('Video plugin check: $e');
      return true;
    }
  }

  /// The clip's first frame as a JPEG next to it (`avatar.mp4` gives
  /// `avatar.jpg`), for a
  /// video that came without a still. Null when it can't be played here.
  static Future<File?> stillFrom(File video) async {
    if (!_available) return null;
    Player? player;
    try {
      player = Player(configuration: const PlayerConfiguration(muted: true));
      await player.open(Media(video.uri.toString()), play: false);
      await player.stream.width
          .firstWhere((w) => w != null && w > 0)
          .timeout(const Duration(seconds: 10));
      final bytes = await player.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) return null;
      final still = File(p.setExtension(video.path, '.jpg'));
      await still.writeAsBytes(bytes);
      return still;
    } catch (e) {
      debugPrint('No still from the video: $e');
      return null;
    } finally {
      await player?.dispose();
    }
  }
}
