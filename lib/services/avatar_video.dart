import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Video portraits: a short clip (`avatar.mp4` or `.webm`) next to the
/// companion's still picture, played muted and looping. Soulkyn gives some
/// characters one. Needs libmpv: bundled on Windows, the system's on Linux.
/// Without it the still picture shows, as before.
class AvatarVideo {
  /// Whether libmpv was found, so a video portrait can play.
  static bool get available => _available;
  static bool _available = false;

  /// Called once at startup.
  static void init() {
    try {
      MediaKit.ensureInitialized();
      _available = true;
    } catch (e) {
      debugPrint('Video portraits unavailable: $e');
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
