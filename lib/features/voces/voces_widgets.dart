import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Small pieces the Voces Mundi screens share.

/// The warm colours of Voces Mundi's own mark.
const vocesColors = [Color(0xFFFF9A5A), Color(0xFF7A2F5C)];

/// The colours of something without a picture: one of a set of hand-picked
/// palettes (light, middle, deep), nudged a little in hue and brightness,
/// at its own angle with two soft glows, all from one seed. Each item keeps
/// its look between starts, and no two quite match.
class ArtLook {
  ArtLook._(this.colors, this.begin, this.glows);

  /// Light, middle and deep colours that sit well together.
  static const palettes = [
    [0xFFFFB38A, 0xFFD9668C, 0xFF3B1F4A], // dusk
    [0xFFFFC46B, 0xFFE0603A, 0xFF4A1A22], // ember
    [0xFF8EE3F5, 0xFF3A7BD5, 0xFF13203F], // ocean
    [0xFF9CF6C8, 0xFF3BB3A0, 0xFF1B2D4A], // aurora
    [0xFFE3C6FF, 0xFF9A6BE0, 0xFF2A1B4D], // lavender
    [0xFFFFC2D1, 0xFFE0577F, 0xFF3D1530], // rose
    [0xFFC9E6A3, 0xFF4E9A6B, 0xFF15302A], // forest
    [0xFFA6B8FF, 0xFF6B5BD6, 0xFF1C1840], // twilight
    [0xFFF7D9A6, 0xFFC98A5A, 0xFF3E2420], // desert
    [0xFFD8ECFF, 0xFF7FA8E0, 0xFF1F2C4F], // frost
    [0xFFA8F0D8, 0xFF2E9C8A, 0xFF0F2A2E], // jade
    [0xFFFFD08A, 0xFFF07A6A, 0xFF2A3A6A], // sunset over water
    [0xFFF5B3F0, 0xFFB84FBF, 0xFF2E1440], // orchid
    [0xFFE8D58A, 0xFF8A9A4A, 0xFF232A1A], // moss and gold
    [0xFFFFB5A0, 0xFFE07A9C, 0xFF2A2350], // coral
    [0xFFC3CCE0, 0xFF5F6F94, 0xFF1A1F2E], // storm
    [0xFF8FD3FF, 0xFFB45CF0, 0xFF1A1036], // neon
    [0xFFE8A0A8, 0xFF8C2F4A, 0xFF220E1A], // wine
  ];

  factory ArtLook.of(int seed) {
    final r = Random(seed);
    double between(double a, double b) => a + r.nextDouble() * (b - a);
    final palette = palettes[r.nextInt(palettes.length)];
    // One shift for all three keeps them in harmony.
    final hue = between(-10, 10);
    Color nudge(int c) {
      final hsl = HSLColor.fromColor(Color(c));
      return hsl
          .withHue((hsl.hue + hue) % 360)
          .withLightness((hsl.lightness + between(-0.04, 0.04)).clamp(0, 1))
          .toColor();
    }

    final colors = [for (final c in palette) nudge(c)];
    final angle = r.nextDouble() * 2 * pi;
    final begin = Alignment(cos(angle), sin(angle));
    return ArtLook._(colors, begin, [
      // The light colour pooling near where the gradient starts…
      (
        at: Alignment(begin.x * between(0.2, 0.8), begin.y * between(0.2, 0.8)),
        color: colors[0].withValues(alpha: between(0.35, 0.55)),
        radius: between(0.7, 1.1),
      ),
      // …and the middle one somewhere across from it.
      (
        at: Alignment(between(-0.9, 0.9), between(-0.9, 0.9)),
        color: colors[1].withValues(alpha: between(0.25, 0.45)),
        radius: between(0.5, 0.9),
      ),
    ]);
  }

  /// For something saved before it had a seed: one from its name.
  factory ArtLook.named(String name) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return ArtLook.of(h);
  }

  final List<Color> colors;
  final Alignment begin;
  final List<({Alignment at, Color color, double radius})> glows;

  Widget build() {
    Widget art = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: begin,
          end: -begin,
          colors: colors,
          stops: const [0, 0.5, 1],
        ),
      ),
    );
    for (final g in glows) {
      art = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: g.at,
            radius: g.radius,
            colors: [g.color, g.color.withValues(alpha: 0)],
          ),
        ),
        child: art,
      );
    }
    return art;
  }
}

/// A picture filling its box, or the item's colours when it has none or the
/// file is gone.
class VocesArt extends StatelessWidget {
  const VocesArt({
    super.key,
    required this.name,
    this.seed,
    this.file,
    this.child,
  });

  final String name;

  /// The item's own colours ([VocesWorld.art], [VocesCharacter.art]).
  final int? seed;
  final File? file;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final fallback = (seed == null ? ArtLook.named(name) : ArtLook.of(seed!))
        .build();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (file == null)
          fallback
        else
          Image.file(
            file!,
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.4),
            errorBuilder: (_, _, _) => fallback,
          ),
        ?child,
      ],
    );
  }
}

/// A round portrait, or the first letter of the name on its colours.
class VocesAvatar extends StatelessWidget {
  const VocesAvatar({
    super.key,
    required this.name,
    this.seed,
    this.file,
    this.size = 36,
    this.radius,
  });

  final String name;
  final int? seed;
  final File? file;
  final double size;

  /// Corner radius; round by default.
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? size / 2),
      child: SizedBox.square(
        dimension: size,
        child: VocesArt(
          name: name,
          seed: seed,
          file: file,
          child: file != null
              ? null
              : Center(
                  child: Text(
                    letter,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: size * 0.4,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The small capitals over a group: CONTINUE, WORLDS…
class VocesLabel extends StatelessWidget {
  const VocesLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w600,
      color: context.palette.textMuted,
    ),
  );
}

/// A rounded filter or tag pill; [onTap] null makes it a plain tag.
class VocesPill extends StatelessWidget {
  const VocesPill(this.label, {super.key, this.on = false, this.onTap});

  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final palette = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: on ? accent.withValues(alpha: 0.22) : palette.tile,
            border: Border.all(
              color: on ? accent.withValues(alpha: 0.6) : palette.glassBorder,
            ),
          ),
          // Only as wide as its label, in a Wrap or a Column alike.
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: on ? palette.text : palette.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A faint box inside a panel, for a group of details.
class VocesBox extends StatelessWidget {
  const VocesBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.highlight,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// A border colour that makes the box stand out (a lore entry that
  /// matched).
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: highlight == null
            ? palette.tile
            : highlight!.withValues(alpha: 0.1),
        border: Border.all(
          color: highlight?.withValues(alpha: 0.7) ?? palette.glassBorder,
        ),
      ),
      child: child,
    );
  }
}

/// A card that lifts a little under the pointer.
class VocesCard extends StatefulWidget {
  const VocesCard({
    super.key,
    required this.child,
    this.onTap,
    this.dashed = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool dashed;

  @override
  State<VocesCard> createState() => _VocesCardState();
}

class _VocesCardState extends State<VocesCard> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.015 : 1,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: widget.dashed ? Colors.transparent : palette.tile,
              border: Border.all(
                color: _hover
                    ? accent.withValues(alpha: 0.6)
                    : palette.glassBorder,
              ),
              boxShadow: [
                if (_hover)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
              ],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Splits "a, b,  c" into tags.
List<String> splitTags(String text) => [
  for (final t in text.split(','))
    if (t.trim().isNotEmpty) t.trim(),
];

/// Asks before something is deleted for good.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String body,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;
