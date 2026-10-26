/// Ready-made looks: an accent and the glow colours behind the panels, so
/// the whole app changes, not just the buttons. Colours are ARGB.
class Look {
  const Look(
    this.id,
    this.label,
    this.accent,
    this.colors,
    this.layout, {
    this.base,
    this.panel,
    this.lightBase,
    this.lightPanel,
    this.orb,
    this.highlight,
  });

  final String id;
  final String label;
  final int accent;
  final List<int> colors;
  final double layout;

  /// For a special colorway: the window and panel colours in the dark and
  /// light theme, so the whole app takes its tint.
  final int? base;
  final int? panel;
  final int? lightBase;
  final int? lightPanel;

  /// A sharp accent for a few spots only, when [accent] is kept quiet.
  final int? highlight;

  /// The colours shown in its orb; the glow colours when null.
  final List<int>? orb;
  List<int> get orbColors => orb ?? colors;

  /// Colorways that recolour everything, not just the glows and accent.
  static const special = [
    Look(
      'haru',
      'Haru',
      // Monochrome: a pale grey does the everyday tinting, and red only
      // marks the few things that matter.
      0xFFCFCFCF,
      [0xFFFFFFFF, 0xFF3A3A3A, 0xFF7A1517],
      0.2,
      base: 0xFF0A0A0A,
      panel: 0xD9161616,
      lightBase: 0xFFF2F2F2,
      lightPanel: 0xE6FFFFFF,
      orb: [0xFFFFFFFF, 0xFF0A0A0A, 0xFFE5383B],
      highlight: 0xFFE5383B,
    ),
    Look(
      'vibecoder',
      "Vibecoder's",
      0xFF6366F1,
      [0xFF4F46E5, 0xFF818CF8, 0xFF312E81],
      0.45,
      base: 0xFF0A0A1F,
      panel: 0xD914143A,
      lightBase: 0xFFECEEFF,
      lightPanel: 0xE6FFFFFF,
      orb: [0xFF818CF8, 0xFF0A0A1F, 0xFF4F46E5],
    ),
    Look(
      'sakura',
      'Sakura',
      0xFFFF8FB1,
      [0xFFFFC2D4, 0xFFFF8FB1, 0xFFFFFFFF],
      0.65,
      base: 0xFF160C12,
      panel: 0xD9231621,
      lightBase: 0xFFFFF2F6,
      lightPanel: 0xE6FFFFFF,
      orb: [0xFFFFFFFF, 0xFF160C12, 0xFFFF8FB1],
    ),
  ];

  bool get isSpecial => base != null;

  static const all = [
    Look('twilight', 'Twilight', 0xFFB18CFF, [
      0xFFB18CFF,
      0xFF4F7CFF,
      0xFFFF7AB6,
    ], 0.12),
    Look('rose', 'Rose', 0xFFFF7AB6, [0xFFFF7AB6, 0xFFFFB86B, 0xFFB18CFF], 0.3),
    Look('ocean', 'Ocean', 0xFF4FC3F7, [
      0xFF2F6BFF,
      0xFF4FC3F7,
      0xFF36D6B5,
    ], 0.55),
    Look('forest', 'Forest', 0xFF5BD6A0, [
      0xFF2E9E6B,
      0xFF9AD66B,
      0xFF2F8FA6,
    ], 0.7),
    Look('ember', 'Ember', 0xFFFFA05B, [
      0xFFFF5B5B,
      0xFFFFA05B,
      0xFFFFD36B,
    ], 0.85),
    Look('mono', 'Moonlight', 0xFFB8C4D6, [
      0xFF8C9BB3,
      0xFF5C6B85,
      0xFFD6DEEB,
    ], 0.4),
  ];

  static Look? byId(String? id) {
    for (final l in [...all, ...special]) {
      if (l.id == id) return l;
    }
    return null;
  }
}
