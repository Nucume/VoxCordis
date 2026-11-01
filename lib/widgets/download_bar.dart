import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The bar every download uses: a thick accent gradient with a light sweep
/// over it, the percentage under it on the left and the time left on the
/// right. A null [progress] shows a slow slide, for when the size is not
/// known yet. Set [showText] false where the surrounding text already says
/// it (e.g. the status of a drawing).
class DownloadBar extends StatefulWidget {
  const DownloadBar({super.key, required this.progress, this.showText = true});

  final double? progress;
  final bool showText;

  @override
  State<DownloadBar> createState() => _DownloadBarState();
}

class _DownloadBarState extends State<DownloadBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  final _samples = <(int, double)>[]; // (ms, progress)
  final _clock = Stopwatch()..start();
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    _note();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate = !MediaQuery.disableAnimationsOf(context);
    if (_animate && !_motion.isAnimating) {
      _motion.repeat();
    } else if (!_animate) {
      _motion.stop();
    }
  }

  @override
  void didUpdateWidget(DownloadBar old) {
    super.didUpdateWidget(old);
    _note();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _note() {
    final p = widget.progress;
    if (p == null) {
      _samples.clear();
      return;
    }
    final now = _clock.elapsedMilliseconds;
    // A smaller value means a new download started in the same bar.
    if (_samples.isNotEmpty && p < _samples.last.$2) _samples.clear();
    _samples.add((now, p));
    _samples.removeWhere((s) => now - s.$1 > 10000);
  }

  /// Time left from the speed over the last ten seconds, or null while there
  /// is too little to go on.
  Duration? get _left {
    final p = widget.progress;
    if (p == null || _samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final ms = last.$1 - first.$1;
    final gained = last.$2 - first.$2;
    if (ms < 3000 || gained <= 0) return null;
    final seconds = (1 - p) * ms / gained / 1000;
    return Duration(seconds: seconds.ceil());
  }

  static String _span(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '$s s';
    if (s < 3600) return '${s ~/ 60} min ${s % 60} s';
    return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    final p = widget.progress?.clamp(0.0, 1.0);
    final left = _left;
    final style = TextStyle(fontSize: 11.5, color: palette.textMuted);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 12,
          child: AnimatedBuilder(
            animation: _motion,
            builder: (context, _) => CustomPaint(
              painter: _BarPainter(
                value: p,
                phase: _motion.value,
                animate: _animate,
                accent: scheme.primary,
                track: scheme.onSurface.withValues(alpha: 0.12),
              ),
            ),
          ),
        ),
        if (widget.showText) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                p == null ? '…' : '${(p * 100).floor()}%',
                style: style.copyWith(
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              if (p != null && p < 1)
                Text(
                  left == null ? 'calculating…' : 'about ${_span(left)} left',
                  style: style,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.value,
    required this.phase,
    required this.animate,
    required this.accent,
    required this.track,
  });

  final double? value;
  final double phase;
  final bool animate;
  final Color accent;
  final Color track;

  /// The accent's slightly lighter, slightly warmer neighbour, so the fill
  /// is a gradient in every Colorway (Haru's red ends in a lighter red, not
  /// the dark grey of its glows).
  static Color _partner(Color c) {
    final h = HSLColor.fromColor(c);
    return h
        .withHue((h.hue + 24) % 360)
        .withLightness(min(0.85, h.lightness + 0.08))
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final full = RRect.fromRectAndRadius(Offset.zero & size, r);
    canvas.drawRRect(full, Paint()..color = track);

    final double left;
    final double right;
    if (value == null) {
      // Unknown size: a third of the bar slides back and forth.
      final t = Curves.easeInOut.transform(
        phase < 0.5 ? phase * 2 : (1 - phase) * 2,
      );
      left = (size.width * 0.65) * t;
      right = left + size.width * 0.35;
    } else {
      left = 0;
      right = max(size.height, size.width * value!);
    }
    final fill = Rect.fromLTRB(left, 0, min(right, size.width), size.height);
    canvas.save();
    canvas.clipRRect(full);
    final fillShape = RRect.fromRectAndRadius(fill, r);
    canvas.drawRRect(
      fillShape,
      Paint()
        ..shader = LinearGradient(
          colors: [accent, _partner(accent)],
        ).createShader(fill),
    );
    if (animate) {
      canvas.clipRRect(fillShape);
      final w = max(40.0, fill.width * 0.5);
      final x = fill.left - w + (fill.width + w) * phase;
      final sweep = Rect.fromLTWH(x, 0, w, size.height);
      canvas.drawRect(
        sweep,
        Paint()
          ..shader = LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.5),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(sweep),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BarPainter o) =>
      o.value != value ||
      o.phase != phase ||
      o.accent != accent ||
      o.track != track ||
      o.animate != animate;
}
