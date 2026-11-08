import 'dart:math';

import '../../data/voces/story_log.dart';
import '../../data/voces/voces_models.dart';

/// What a story keeps track of beside its turns: what the player carries,
/// what is still to do, and how the people met feel about them. The
/// narrator keeps it up to date every few turns; the human can edit it.
class StoryNotes {
  const StoryNotes({
    this.items = const [],
    this.quests = const [],
    this.feelings = const {},
  });

  final List<String> items;
  final List<String> quests;

  /// Name → how they feel about the player, in a few words.
  final Map<String, String> feelings;

  bool get isEmpty => items.isEmpty && quests.isEmpty && feelings.isEmpty;

  /// How many told turns pass between updates.
  static const every = 6;

  Map<String, Object?> toJson() => {
    if (items.isNotEmpty) 'items': items,
    if (quests.isNotEmpty) 'quests': quests,
    if (feelings.isNotEmpty) 'feelings': feelings,
  };

  static StoryNotes fromJson(Object? json) {
    if (json is! Map) return const StoryNotes();
    List<String> list(Object? v) => [
      for (final x in (v as List?) ?? const [])
        if (x is String && x.trim().isNotEmpty) x.trim(),
    ];
    final f = json['feelings'];
    return StoryNotes(
      items: list(json['items']),
      quests: list(json['quests']),
      feelings: {
        if (f is Map)
          for (final e in f.entries)
            if (e.key is String && e.value is String) e.key: e.value,
      },
    );
  }

  /// The notes as the writers read them, in the prompt.
  String forPrompt(String player) => [
    if (items.isNotEmpty) '$player carries: ${items.join(', ')}',
    if (quests.isNotEmpty) 'Still to do: ${quests.join('; ')}',
    for (final e in feelings.entries) '${e.key} towards $player: ${e.value}',
  ].join('\n');

  /// The notes as editable text, and back: the same three parts.
  String get itemsText => items.join('\n');
  String get questsText => quests.join('\n');
  String get feelingsText =>
      [for (final e in feelings.entries) '${e.key}: ${e.value}'].join('\n');

  static StoryNotes fromText({
    required String items,
    required String quests,
    required String feelings,
  }) {
    List<String> lines(String t) => [
      for (final l in t.split('\n'))
        if (_clean(l).isNotEmpty) _clean(l),
    ];
    return StoryNotes(
      items: lines(items),
      quests: lines(quests),
      feelings: _feelings(lines(feelings)),
    );
  }

  static String _clean(String l) =>
      l.replaceAll(RegExp(r'^[\s\-*•]+'), '').replaceAll('**', '').trim();

  static Map<String, String> _feelings(List<String> lines) => {
    for (final l in lines)
      if (l.indexOf(':') case final i when i > 0 && i < l.length - 1)
        l.substring(0, i).trim(): l.substring(i + 1).trim(),
  };

  /// What the model is asked to keep the notes.
  static String instructions(String player) =>
      '''
You keep the notes of a roleplay story: what $player carries, what is still
to be done, and how the people $player met feel about them. Update the
notes from what happened in the new part of the story: add, change or
remove. Keep each line short. Only what the story shows; no guesses.

Answer in exactly this form, nothing else:
Items:
- one thing per line (or "- none")
Quests:
- one open goal or promise per line (or "- none")
Feelings:
- Name: how they feel about $player, a few words (or "- none")''';

  static String brief(StoryNotes now, String player, String newPart) => [
    'The notes so far:',
    'Items:',
    if (now.items.isEmpty) '- none' else for (final i in now.items) '- $i',
    'Quests:',
    if (now.quests.isEmpty) '- none' else for (final q in now.quests) '- $q',
    'Feelings:',
    if (now.feelings.isEmpty)
      '- none'
    else
      for (final e in now.feelings.entries) '- ${e.key}: ${e.value}',
    '',
    'The new part of the story:',
    newPart,
  ].join('\n');

  /// The notes in [reply]; null when it has none of the three parts.
  static StoryNotes? parse(String reply) {
    final t = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final parts = <String, List<String>>{};
    String? at;
    for (final raw in t.split('\n')) {
      final head = RegExp(
        r'^[#*\s]*(items|quests|feelings)[*\s]*:[*\s]*(.*)$',
        caseSensitive: false,
      ).firstMatch(raw);
      if (head != null) {
        at = head.group(1)!.toLowerCase();
        parts[at] = [];
        final rest = _clean(head.group(2)!);
        if (rest.isNotEmpty) parts[at]!.addAll(rest.split(RegExp(r',\s*')));
        continue;
      }
      final l = _clean(raw);
      if (at == null || l.isEmpty || l.toLowerCase() == 'none') continue;
      parts[at]!.add(l);
    }
    if (parts.isEmpty) return null;
    List<String> of(String k) => [
      for (final l in parts[k] ?? const <String>[])
        if (l.toLowerCase() != 'none') l,
    ];
    return StoryNotes(
      items: of('items'),
      quests: of('quests'),
      feelings: _feelings(of('feelings')),
    );
  }
}

/// A roll for a risky turn: 1 to 20, and what it means for the story.
abstract final class Fortune {
  /// Whether [turn] gets a roll on its own: an action by the player in a
  /// Punishing or Grimdark story.
  static bool rollsOnItsOwn(StoryTurn turn, Difficulty difficulty) {
    if (difficulty != Difficulty.punishing &&
        difficulty != Difficulty.grimdark) {
      return false;
    }
    return turn.kind == TurnKind.act ||
        (turn.kind == TurnKind.say && turn.text.contains('*'));
  }

  static int roll([Random? random]) => (random ?? Random()).nextInt(20) + 1;

  /// How [n] turns out, in words.
  static String outcome(int n) => switch (n) {
    1 => 'it goes as badly as it could',
    <= 5 => 'it fails, and it costs them',
    <= 10 => 'it fails, or works only at a price',
    <= 15 => 'it works, with a catch',
    <= 19 => 'it works',
    _ => 'it works better than hoped',
  };

  /// What the writer of the reply is told about [n].
  static String forPrompt(int n, String player) =>
      '(Fortune for what $player just tried: $n out of 20, so '
      '${outcome(n)}. If it was risky, show that outcome; if it was '
      'trivial, ignore this. Never mention dice or numbers.)';
}
