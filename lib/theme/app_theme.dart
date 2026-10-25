import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

/// The app's colours for one brightness: frosted, mostly solid panels over
/// soft colour glows on a solid base.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.glass,
    required this.glassBorder,
    required this.glassSheen,
    required this.text,
    required this.textMuted,
    required this.tile,
    required this.bubble,
    required this.codeFill,
    required this.glowAlpha,
  });

  final Color background;

  /// Panel fill: mostly solid, so the glows only tint it a little.
  final Color glass;
  final Color glassBorder;

  /// The soft light across a panel, top left to bottom right.
  final List<Color> glassSheen;

  /// Full-strength text and marks, e.g. the selected tab.
  final Color text;
  final Color textMuted;

  /// A faint fill for tiles and boxes inside a panel.
  final Color tile;

  /// The companion's chat bubbles.
  final Color bubble;

  /// Behind `code` in chat.
  final Color codeFill;

  /// How strong the background glows are at their centre.
  final double glowAlpha;

  static const dark = AppPalette(
    background: Color(0xFF0E0B16),
    glass: Color(0xD91B1727),
    glassBorder: Color(0x33FFFFFF),
    glassSheen: [Color(0x14FFFFFF), Color(0x05FFFFFF)],
    text: Color(0xFFFFFFFF),
    textMuted: Color(0xB3FFFFFF),
    tile: Color(0x12FFFFFF),
    bubble: Color(0x1AFFFFFF),
    codeFill: Color(0x22FFFFFF),
    glowAlpha: 0.35,
  );

  /// Light: near-white panels and dark text. The glows are a little weaker
  /// so the base stays bright, and muted text stays above 4.5:1 on a panel.
  static const light = AppPalette(
    background: Color(0xFFF3F0F8),
    glass: Color(0xE0FFFFFF),
    glassBorder: Color(0x1F000000),
    glassSheen: [Color(0x33FFFFFF), Color(0x0AFFFFFF)],
    text: Color(0xFF1B1726),
    textMuted: Color(0xA6000000),
    tile: Color(0x0A000000),
    bubble: Color(0x0F000000),
    codeFill: Color(0x14000000),
    glowAlpha: 0.28,
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? dark;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      background: Color.lerp(background, other.background, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassSheen: [
        for (var i = 0; i < glassSheen.length; i++)
          Color.lerp(glassSheen[i], other.glassSheen[i], t)!,
      ],
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      tile: Color.lerp(tile, other.tile, t)!,
      bubble: Color.lerp(bubble, other.bubble, t)!,
      codeFill: Color.lerp(codeFill, other.codeFill, t)!,
      glowAlpha: lerpDouble(glowAlpha, other.glowAlpha, t)!,
    );
  }
}

extension AppPaletteContext on BuildContext {
  AppPalette get palette => AppPalette.of(this);
}

class AppTheme {
  static const heartMark = 'assets/brand/heart_mark.png';
  static const appIcon = 'assets/brand/app_icon.png';

  static ThemeData dark(Color accent) => build(accent, Brightness.dark);
  static ThemeData light(Color accent) => build(accent, Brightness.light);

  static ThemeData build(Color accent, Brightness brightness) {
    final palette = brightness == Brightness.light
        ? AppPalette.light
        : AppPalette.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      // Keep the chosen colour recognisable instead of a muted tone of it.
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      brightness: brightness,
      surface: Colors.transparent,
    );
    // Tooltips and toasts float over anything, so they get a solid panel
    // tinted with the accent instead of Material's plain black or white.
    final popup = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.10),
      Color.alphaBlend(palette.glass, palette.background),
    );
    final popupBorder = Border.all(
      color: Color.alphaBlend(
        scheme.primary.withValues(alpha: 0.25),
        palette.glassBorder,
      ),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: [palette],
      tooltipTheme: TooltipThemeData(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: TextStyle(fontSize: 12.5, color: palette.text),
        waitDuration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: popup,
          borderRadius: BorderRadius.circular(12),
          border: popupBorder,
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        width: 380,
        elevation: 2,
        backgroundColor: popup,
        contentTextStyle: TextStyle(fontSize: 14, color: palette.text),
        actionTextColor: scheme.primary,
        closeIconColor: palette.textMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: popupBorder.top,
        ),
      ),
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      splashFactory: InkSparkle.splashFactory,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.light
            ? const Color(0x0F000000)
            : const Color(0x14FFFFFF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// A frosted panel: blurs whatever is behind it and adds a soft edge.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.blur = 12,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final palette = context.palette;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: r,
            color: palette.glass,
            border: Border.all(color: palette.glassBorder, width: 1),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: palette.glassSheen,
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Colour glows behind the panels, on a solid base: a see-through window
/// made the whole app hard to read.
///
/// They drift only while [animate] is on (during setup). Every moving frame
/// makes each glass panel blur again, which competes with a local model for
/// the graphics card, so the rest of the time they are painted once and
/// stay put where [layout] puts them.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({
    super.key,
    required this.accent,
    required this.child,
    this.colors = const [],
    this.layout = defaultLayout,
    this.animate = false,
  });

  final Color accent;
  final Widget child;

  /// Up to three glow colours; empty means the accent, blue and pink.
  final List<Color> colors;

  /// Where the glows sit, from 0 to 1.
  final double layout;
  final bool animate;

  static const defaultLayout = 0.12;
  static const defaultColors = [Color(0xFF4F7CFF), Color(0xFFFF7AB6)];

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
    value: widget.layout,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(AuroraBackground old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.animate) {
      _c.stop();
      _c.value = widget.layout;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colors = [
      ...widget.colors,
      if (widget.colors.isEmpty) ...[
        widget.accent,
        ...AuroraBackground.defaultColors,
      ],
    ];
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _AuroraPainter(_c.value, colors, palette),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t, this.colors, this.palette);
  final double t;
  final List<Color> colors;
  final AppPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      // Solid: the desktop no longer shows through the window.
      Paint()..color = palette.background,
    );
    const sizes = [0.55, 0.45, 0.35];
    final blobs = [
      for (var i = 0; i < colors.length && i < 3; i++)
        (colors[i], i / 3, sizes[i]),
    ];
    for (final (color, phase, radius) in blobs) {
      final a = (t + phase) * 2 * math.pi;
      final center = Offset(
        size.width * (0.5 + 0.35 * math.sin(a)),
        size.height * (0.5 + 0.3 * math.sin(a * 2 + 1)),
      );
      final r = size.shortestSide * radius;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: palette.glowAlpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.t != t || old.palette != palette || !listEquals(old.colors, colors);
}
