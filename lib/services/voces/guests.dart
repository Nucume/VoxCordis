import 'dart:math';

import '../../data/voces/story_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import 'story_engine.dart';

/// Guests: characters from elsewhere in the library who turn up in a world
/// they aren't cast in, when the world (or the story) lets them.
///
/// Nothing about them reaches the narrator's prompt until one arrives: the
/// app rolls for a guest now and then, ranks who could come by how well
/// they fit, and asks the model a short question to pick one (or none).
/// Only then is their sheet copied into the story. Pure helpers; the story
/// session runs the model.
abstract final class Guests {
  /// How many of the best fits the model chooses from.
  static const offer = 4;

  /// Told turns after a guest arrives before another may come on their own
  /// (a story's first turns count too, so nobody drops in at once).
  static const pause = 10;

  /// Guests in the scene at which no more come on their own.
  static const crowd = 2;

  /// Chance, before a narrator turn, that a guest turns up: well below
  /// the world's own cast coming and going.
  static double chance(Liveliness l) => l.arrive * 0.4;

  /// Whether guests may come in a story: its own switch, else [world]'s
  /// rule.
  static bool open(VocesWorld world, StoryState state) =>
      state.guests ?? world.guests != GuestRule.none;

  /// Whether a guest is due before the next narrator turn, given a [roll]
  /// between 0 and 1.
  static bool due(StoryState state, List<StoryTurn> turns, double roll) {
    final here = state.present.where(state.guestIds.contains).length;
    if (here >= crowd) return false;
    final since = turns
        .where((t) => t.id > state.guestAt && !t.kind.aside)
        .length;
    if (since < pause) return false;
    return roll < chance(state.liveliness);
  }

  /// The worlds [c] is cast in.
  static List<VocesWorld> homes(VocesCharacter c, List<VocesWorld> worlds) => [
    for (final w in worlds)
      if (w.castIds.contains(c.id)) w,
  ];

  /// Who from [library] may turn up in [story], by [rules] (the world as it
  /// is in the library now, or the story's copy when it's gone).
  ///
  /// Never the player, nobody already in the story or cast in the world,
  /// nobody who stays home, and nobody barred (or not picked). Someone cast
  /// only in 18+ worlds doesn't turn up in a world that isn't one.
  static List<VocesCharacter> allowed({
    required VocesWorld rules,
    required StoryWorld story,
    required StoryState state,
    required List<VocesCharacter> library,
    required List<VocesWorld> worlds,
    required bool mature,
  }) {
    final hostAdult = mature && story.world.adult;
    final taken = {
      for (final c in story.cast.values) c.name.trim().toLowerCase(),
      for (final e in state.extras) e.name.trim().toLowerCase(),
      story.story.playerName.trim().toLowerCase(),
    };
    return [
      for (final c in library)
        if (c.visits &&
            c.id != story.story.playerId &&
            !story.cast.containsKey(c.id) &&
            !rules.castIds.contains(c.id) &&
            !story.world.castIds.contains(c.id) &&
            !taken.contains(c.name.trim().toLowerCase()) &&
            switch (rules.guests) {
              GuestRule.picked => rules.guestIds.contains(c.id),
              // A story switched on in a closed world: anyone not barred.
              _ => !rules.barredIds.contains(c.id),
            } &&
            (hostAdult || !_adultOnly(c, worlds)))
          c,
    ];
  }

  static bool _adultOnly(VocesCharacter c, List<VocesWorld> worlds) {
    final h = homes(c, worlds);
    return h.isNotEmpty && h.every((w) => w.adult);
  }

  /// What a candidate is, for ranking and for the model: who they are and
  /// where they come from.
  static String profile(VocesCharacter c, List<VocesWorld> worlds) {
    final h = homes(c, worlds);
    return [
      c.line.isEmpty ? c.name : '${c.name}: ${_cut(c.line, 200)}',
      if (c.tags.isNotEmpty) 'Traits: ${c.tags.take(8).join(', ')}',
      if (h.isNotEmpty)
        'Usually in: ${[for (final w in h.take(3)) w.tags.isEmpty ? w.name : '${w.name} (${w.tags.join(', ')})'].join('; ')}',
    ].join('. ');
  }

  /// The world and the moment, to rank candidates against.
  static String scene(VocesWorld world, String place, String recent) => [
    '${world.name}${world.line.isEmpty ? '' : ': ${world.line}'}',
    if (world.tags.isNotEmpty) world.tags.join(', '),
    _cut(world.setting, 600),
    if (place.isNotEmpty) 'Where: $place',
    _cut(recent, 1200),
  ].where((s) => s.trim().isNotEmpty).join('\n');

  /// How alike [a] and [b] are by the words they share, for when the
  /// Recall model isn't there: 0 to 1.
  static double wordScore(String a, String b) {
    final x = _words(a), y = _words(b);
    if (x.isEmpty || y.isEmpty) return 0;
    final shared = x.intersection(y).length;
    return shared / sqrt(x.length * y.length);
  }

  /// [people] best fit first, by [scores] (one each, higher fits better),
  /// shaken a little by [random] so the same few don't always win; at
  /// most [offer].
  static List<VocesCharacter> best(
    List<VocesCharacter> people,
    List<double> scores,
    Random random,
  ) {
    final order = [for (var i = 0; i < people.length; i++) i];
    final shaken = [
      for (var i = 0; i < people.length; i++)
        scores[i] * (0.8 + 0.4 * random.nextDouble()),
    ];
    order.sort((a, b) => shaken[b].compareTo(shaken[a]));
    return [for (final i in order.take(offer)) people[i]];
  }

  static const pickerInstructions =
      'You help run a roleplay story. Someone from the list may walk into '
      'the scene now. Pick the one person who could most believably turn '
      'up here at this moment, given the world and what is happening. '
      'They will be fitted into this world (their job, home and past '
      'adjusted to it), so where they usually live doesn\'t matter; who '
      'they are and the kind of story does. Answer "none" when nobody '
      'fits, or when the moment is wrong for a newcomer: a private or '
      'tense moment, or a place nobody could get into. Answer with the '
      'name exactly as written, or "none", and nothing else.';

  static String pickerBrief({
    required VocesWorld world,
    required String place,
    required String recent,
    required List<VocesCharacter> candidates,
    required List<VocesWorld> worlds,
  }) {
    final b = StringBuffer()
      ..writeln('# The world')
      ..writeln('${world.name}${world.line.isEmpty ? '' : ': ${world.line}'}');
    if (world.tags.isNotEmpty) {
      b.writeln('Tags: ${world.tags.join(', ')}');
    }
    if (world.setting.trim().isNotEmpty) {
      b.writeln(_cut(world.setting.trim(), 700));
    }
    if (place.isNotEmpty) b.writeln('Where: $place');
    b
      ..writeln()
      ..writeln('# The scene now')
      ..writeln(_cut(recent, 1500))
      ..writeln()
      ..writeln('# Who could turn up');
    for (final c in candidates) {
      b.writeln('- ${profile(c, worlds)}');
    }
    b
      ..writeln()
      ..write('Answer with one name, or none.');
    return b.toString();
  }

  /// The candidate the model picked, or null for none (or nothing usable).
  static VocesCharacter? parsePick(
    String reply,
    List<VocesCharacter> candidates,
  ) {
    final text = reply
        .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
        .trim()
        .toLowerCase();
    if (text.isEmpty) return null;
    VocesCharacter? found;
    var at = -1;
    for (final c in candidates) {
      for (final n in {c.name, c.name.split(' ').first}) {
        if (n.trim().length < 2) continue;
        final m = RegExp(
          '(?<![\\p{L}\\p{N}])${RegExp.escape(n.toLowerCase())}'
          '(?![\\p{L}\\p{N}])',
          unicode: true,
        ).firstMatch(text);
        if (m != null && (at < 0 || m.start < at)) {
          at = m.start;
          found = c;
        }
      }
    }
    final none = RegExp(r'\bnone\b|\bnobody\b|\bno one\b').firstMatch(text);
    if (none != null && (at < 0 || none.start < at)) return null;
    return found;
  }

  /// Told to the narrator as a guest walks in.
  static String arrival(VocesCharacter c, String worldName) =>
      '(${_lineOf(c)} turns up now: show them coming in. They are new to '
      'this story but belong in $worldName: give them a reason to be here '
      'that fits this world, keeping who they are.)';

  /// For the narrator, about guests in the scene.
  static String belongs(List<VocesCharacter> guests, String worldName) =>
      '${guests.map((c) => c.name).join(', ')} came from other stories: '
      'in this one they belong in $worldName, with a life that fits it.';

  /// For a guest's own turns: fit in, and leave their home's rules at
  /// home.
  static String fitIn(VocesCharacter c, String worldName) =>
      '${c.name} wasn\'t made for $worldName, but in this story they belong '
      'here: their job, home and past fit this world, while their '
      'personality, looks and way of talking stay as on their sheet. Leave '
      'out anything on the sheet about another world, its rules, or how to '
      'run a game or story.';

  static String _lineOf(VocesCharacter c) => [
    c.name,
    if (c.pronouns != null && c.pronouns!.isNotEmpty) '(${c.pronouns})',
    if (c.line.isNotEmpty) '- ${c.line}',
  ].join(' ');

  static String _cut(String s, int max) {
    final t = s.trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  // dart format off
  static const _stop = {
    'that', 'this', 'with', 'from', 'they', 'them', 'their', 'there',
    'have', 'what', 'when', 'where', 'which', 'while', 'into', 'your',
    'just', 'like', 'very', 'more', 'some', 'than', 'then', 'been', 'were',
    'will', 'would', 'could', 'about', 'also', 'only', 'over', 'each',
    'loves', 'likes', 'hates', 'always', 'never', 'other', 'here',
  };
  // dart format on

  static Set<String> _words(String s) => {
    for (final m in RegExp(
      r'[\p{L}]{4,}',
      unicode: true,
    ).allMatches(s.toLowerCase()))
      if (!_stop.contains(m.group(0))) _stem(m.group(0)!),
  };

  /// "students" and "student" alike.
  static String _stem(String w) =>
      w.length > 5 && w.endsWith('s') ? w.substring(0, w.length - 1) : w;
}
