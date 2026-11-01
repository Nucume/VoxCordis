import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/desk/pictures.dart';
import '../services/avatar_video.dart';
import '../theme/app_theme.dart';

/// The companion's picture with rounded corners and a glowing accent rim,
/// in the picture's own shape: a tall one stands as a tall rectangle. When
/// a video portrait (`avatar.mp4`) sits next to the picture, it plays over
/// it, muted and looping. Without a picture it shows [placeholder], or the
/// VoxCordis heart, as a square.
class Portrait extends StatefulWidget {
  const Portrait({
    super.key,
    this.path,
    this.size,
    this.maxHeight,
    this.placeholder,
    this.play = true,
  });

  final String? path;

  /// Width; null fills the available width.
  final double? size;

  /// The tallest it may be. A tall picture is made narrower to fit.
  final double? maxHeight;
  final Widget? placeholder;

  /// Whether a video portrait plays (Settings → Appearance).
  final bool play;

  /// Where a picture is cropped when its shape is beyond [minAspect] or
  /// [maxAspect]: tall ones keep their upper part, where the face usually
  /// is, and wide ones their middle. The companion switcher's small square
  /// uses it too.
  static const alignment = Alignment(0, -0.6);

  /// Width over height: no taller than 9:16, no wider than 16:9.
  static const minAspect = 9 / 16;
  static const maxAspect = 16 / 9;

  @override
  State<Portrait> createState() => _PortraitState();
}

class _PortraitState extends State<Portrait> with WidgetsBindingObserver {
  /// Width over height of the picture, once it is known.
  double _aspect = 1;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  Player? _player;
  VideoController? _video;
  bool _playing = false;

  /// The video has faded in over the picture.
  bool _covered = false;

  /// [_aspect] is the playing clip's, not the still's.
  bool _aspectFromVideo = false;

  /// The picture's path and time, and whether a clip sits next to it, as
  /// last loaded: a new picture under the same name is loaded afresh.
  String? _stamp;

  String? _stampOf() {
    final f = _file;
    if (f == null) return null;
    final clip = Pictures.avatarVideoBeside(f.path);
    return '${f.path}@${f.lastModifiedSync().microsecondsSinceEpoch}'
        '|${clip?.lastModifiedSync().microsecondsSinceEpoch}';
  }

  File? get _file {
    final path = widget.path;
    if (path == null) return null;
    final f = File(path);
    return f.existsSync() ? f : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(Portrait old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path ||
        old.play != widget.play ||
        _stampOf() != _stamp) {
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListening();
    _player?.dispose();
    super.dispose();
  }

  /// The video plays only while the window is in front: it pauses when
  /// another window has the focus, or this one is minimised or hidden.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final player = _player;
    if (player == null) return;
    if (state == AppLifecycleState.resumed) {
      player.play();
    } else {
      player.pause();
    }
  }

  void _load() {
    _stopListening();
    _player?.dispose();
    _player = null;
    _video = null;
    _playing = false;
    _covered = false;
    _aspectFromVideo = false;
    _stamp = _stampOf();
    final file = _file;
    if (file == null) {
      _aspect = 1;
      return;
    }
    final stream = FileImage(file).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width, h = info.image.height;
      info.dispose();
      if (!mounted || w <= 0 || h <= 0 || _aspectFromVideo) return;
      setState(() => _aspect = w / h);
    }, onError: (_, _) {});
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
    final clip = Pictures.avatarVideoBeside(file.path);
    if (clip != null && widget.play && AvatarVideo.available) _play(clip);
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  Future<void> _play(File clip) async {
    try {
      final player = Player(
        configuration: const PlayerConfiguration(muted: true),
      );
      final video = VideoController(player);
      _player = player;
      _video = video;
      await player.setPlaylistMode(PlaylistMode.single);
      final state = WidgetsBinding.instance.lifecycleState;
      await player.open(
        Media(clip.uri.toString()),
        play: state == null || state == AppLifecycleState.resumed,
      );
      // The clip's shape wins over the still's, which may differ.
      final w =
          player.state.width ??
          await player.stream.width.firstWhere((w) => w != null && w > 0);
      final h =
          player.state.height ??
          await player.stream.height.firstWhere((h) => h != null && h > 0);
      if (mounted && _player == player && w! > 0 && h! > 0) {
        setState(() {
          _aspect = w / h;
          _aspectFromVideo = true;
        });
      }
      await video.waitUntilFirstFrameRendered;
      if (!mounted || _player != player) return;
      setState(() => _playing = true);
    } catch (e) {
      // No video here after all: the still picture stays.
      debugPrint('Video portrait could not play: $e');
      if (mounted) setState(() => _video = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final file = _file;
    final aspect = file == null
        ? 1.0
        : _aspect.clamp(Portrait.minAspect, Portrait.maxAspect);

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = widget.size ?? constraints.maxWidth;
        final maxHeight = widget.maxHeight;
        if (maxHeight != null && width / aspect > maxHeight) {
          width = maxHeight * aspect;
        }
        final height = width / aspect;
        final radius = width.clamp(0, height) * 0.18;
        final video = _video;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          width: width,
          height: height,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 3),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              // Twilight's pink and blue, or the colorway's own.
              colors: [context.highlight, ...context.palette.rim],
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.25),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: const Color(0xFF0D1426),
              child: file != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        // Keyed by the file's time, so a new picture saved
                        // under the same name (avatar.png) is loaded afresh.
                        // Hidden once the video plays, so a clip with a
                        // see-through frame never shows the picture behind.
                        if (!_covered)
                          Image.file(
                            file,
                            key: ValueKey(
                              '${file.path}@${file.lastModifiedSync().microsecondsSinceEpoch}',
                            ),
                            fit: BoxFit.cover,
                            alignment: Portrait.alignment,
                          ),
                        if (video != null)
                          AnimatedOpacity(
                            opacity: _playing ? 1 : 0,
                            duration: const Duration(milliseconds: 400),
                            onEnd: () {
                              if (_playing) setState(() => _covered = true);
                            },
                            child: Video(
                              controller: video,
                              fit: BoxFit.cover,
                              alignment: Portrait.alignment,
                              controls: NoVideoControls,
                              fill: Colors.transparent,
                              // A portrait mustn't keep the screen awake.
                              wakelock: false,
                            ),
                          ),
                      ],
                    )
                  : Center(
                      child:
                          widget.placeholder ??
                          Padding(
                            padding: EdgeInsets.all(width * 0.18),
                            child: Image.asset(AppTheme.heartMark),
                          ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
