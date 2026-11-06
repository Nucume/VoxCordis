import '../../data/voces/voces_models.dart';

/// What the narrator may show in a story, and how hard the world is on the
/// human's character: lines for the story's prompt (used from part 2).
///
/// - A world that isn't 18+ (or any world while Mature content is off)
///   stays as it is: violence isn't lingered on and intimacy fades out.
///   With Mature content on, love that grows there may show warmly.
/// - An 18+ world may show violence, sex and heavy themes in full. Its tags
///   say what it leans into, but the human leads: where they take the
///   story, the narrator follows, in the world's own tone.
class ContentRules {
  const ContentRules._();

  static String forStory({
    required VocesWorld world,
    required Difficulty difficulty,
    required bool mature,
  }) {
    final adult = mature && world.adult;
    final lines = <String>[
      if (adult) ...[
        'This world is for adults. Violence, sex and heavy themes may be '
            'shown in full when the story goes there; do not fade out or '
            'soften them.',
        'The human leads. If they take the story somewhere else, for '
            'example toward romance or sex in a brutal world, follow them '
            'there and keep the world\'s own tone.',
        'Everyone in a sexual scene is an adult.',
      ] else ...[
        'Keep the story true to its world: violence may happen but is not '
            'lingered on, and nothing sexual is shown explicitly.',
        mature
            ? 'If love grows between characters, let it show warmly: '
                  'affection, a kiss, a tender scene that fades out before '
                  'anything explicit.'
            : 'Romance may happen; keep it to affection and fade out.',
      ],
      ...tagLines(world.tags),
      _difficulty(adult ? difficulty : _capped(difficulty)),
    ];
    return lines.join('\n');
  }

  /// The main tag, which the story always revolves around, and the
  /// others as flavour.
  static List<String> tagLines(List<String> tags) {
    if (tags.isEmpty) return const [];
    final main = tags.first;
    final style = WorldTags.meanings[main]?.style;
    return [
      'Main tag: ${WorldTags.describe(main)}. The story always revolves '
          'around it${style == null ? '' : '; tell it with $style'}. When the '
          'human steers elsewhere, follow, then drift back toward it when '
          'they let you.',
      if (tags.length > 1)
        'Flavour: ${tags.skip(1).map(WorldTags.describe).join('; ')}. These '
            'show now and then, without taking over from the main tag.',
    ];
  }

  /// Grimdark only in 18+ worlds; elsewhere it plays as Punishing.
  static Difficulty _capped(Difficulty d) =>
      d.adultOnly ? Difficulty.punishing : d;

  static String _difficulty(Difficulty d) => switch (d) {
    Difficulty.kind =>
      'Difficulty: Kind. Setbacks sting but heal, help turns up, and the '
          'world leans the human\'s way.',
    Difficulty.neutral =>
      'Difficulty: Neutral. Fair and fitting: choices have the consequences '
          'they would really have, and luck evens out.',
    Difficulty.punishing =>
      'Difficulty: Punishing. Mistakes cost dearly; wounds, losses and '
          'enemies stay, and nobody comes to the rescue for free.',
    Difficulty.grimdark =>
      'Difficulty: Grimdark. Bleak and merciless: hope is scarce, victories '
          'cost something, and death can be final.',
  };
}
