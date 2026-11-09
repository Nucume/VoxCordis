import '../../data/voces/story_log.dart';
import 'sentence_words.dart';

/// Someone the narrator brought in who has no sheet yet: a name and a
/// line, voiced by the narrator, counted as the story goes.
class Extra {
  const Extra(this.name, this.line, {this.seen = 1, this.talked = 0});

  final String name;
  final String line;

  /// Turns that mention them.
  final int seen;

  /// Times the player spoke to them by name.
  final int talked;

  Extra copyWith({String? line, int? seen, int? talked}) => Extra(
    name,
    line ?? this.line,
    seen: seen ?? this.seen,
    talked: talked ?? this.talked,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'line': line,
    'seen': seen,
    'talked': talked,
  };

  static Extra? fromJson(Object? json) {
    if (json is! Map || json['name'] is! String) return null;
    return Extra(
      json['name']! as String,
      json['line'] is String ? json['line']! as String : '',
      seen: json['seen'] is int ? json['seen']! as int : 1,
      talked: json['talked'] is int ? json['talked']! as int : 0,
    );
  }
}

/// The story's cast growing as it is played: extras the narrator brings in
/// are noticed, counted, and the ones who matter get a sheet of their own
/// and speak for themselves; those who leave keep a note of what they went
/// through. Pure helpers; the story view runs the model.
class LivingCast {
  const LivingCast._();

  /// When an extra gets a sheet on their own.
  static const promoteSeen = 4;
  static const promoteTalked = 2;

  /// Extras kept at most; the least seen go first.
  static const maxExtras = 24;

  static bool ripe(Extra e) =>
      e.seen >= promoteSeen || e.talked >= promoteTalked;

  /// Words that are not a person's name either: fillers, places in a
  /// room, and titles on their own.
  // dart format off
  static const _stop = {
    ...sentenceWords,
    'Yes', 'Now', 'Still', 'Just', 'Even', 'Perhaps', 'Maybe', 'Something',
    'Someone', 'Nothing', 'Behind', 'Above', 'Below', 'Outside', 'Inside',
    'Around', 'Through', 'Across', 'Somewhere', 'Too', 'So', 'Place', 'Oh',
    'Well', 'Lord', 'Lady', 'Sir', 'Captain', 'Mister', 'Miss', 'Mrs', 'Mr',
  };
  // dart format on

  /// Capitalised words in [text] that could be a new person's name: not
  /// [known], not a common word.
  static List<String> candidates(String text, Set<String> known) {
    final low = {for (final k in known) k.toLowerCase()};
    final out = <String>{};
    for (final m in RegExp(
      r"\b([A-Z][\p{Ll}'’-]{2,}(?: [A-Z][\p{Ll}'’-]{2,})?)",
      unicode: true,
    ).allMatches(text)) {
      final w = m.group(1)!;
      if (_stop.contains(w.split(' ').first)) continue;
      if (low.contains(w.toLowerCase()) ||
          low.any((k) => k.split(' ').contains(w.toLowerCase()))) {
        continue;
      }
      out.add(w);
    }
    return out.toList();
  }

  static const finderInstructions = '''
You read a passage of a roleplay story and list the people in it who are
named. Leave out places, groups, things and titles without a name.

Answer with one line per person, in this shape, and nothing else:
Name - who they are, in a few words

Answer "none" when no named person is in it.''';

  static String finderBrief(String passage, List<String> known) => [
    if (known.isNotEmpty) 'Already known (leave them out): ${known.join(', ')}',
    'Passage:',
    passage.trim(),
  ].join('\n\n');

  /// The people in [reply] ([finderInstructions]'s shape), without
  /// [known] ones.
  static List<Extra> parseFound(String reply, Set<String> known) {
    final low = {for (final k in known) k.toLowerCase()};
    final out = <Extra>[];
    final text = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    for (final line in text.split('\n')) {
      final m = RegExp(
        r'^\s*(?:[-*•\d.)]+\s*)?\**([^\-–—:*]{2,40}?)\**\s*[-–—:]\s*(.+)$',
      ).firstMatch(line);
      if (m == null) continue;
      final name = m.group(1)!.trim();
      if (name.toLowerCase() == 'none' || low.contains(name.toLowerCase())) {
        continue;
      }
      if (!RegExp(r'^[A-Z]', unicode: true).hasMatch(name)) continue;
      if (name.split(' ').length > 3) continue;
      out.add(Extra(name, m.group(2)!.trim()));
    }
    return out;
  }

  /// Whether [name] (or their first name) is in [text] as a word.
  static bool names(String text, String name) {
    for (final n in {name, name.split(' ').first}) {
      if (n.length < 2) continue;
      if (RegExp(
        '(?<![\\p{L}\\p{N}])${RegExp.escape(n)}(?![\\p{L}\\p{N}])',
        unicode: true,
        caseSensitive: false,
      ).hasMatch(text)) {
        return true;
      }
    }
    return false;
  }

  /// [extras] after [turn]: each one it names is seen once more, or
  /// talked to when the player said it.
  static List<Extra> count(List<Extra> extras, StoryTurn turn) => [
    for (final e in extras)
      if (!names(turn.text, e.name))
        e
      else if (turn.kind == TurnKind.say)
        e.copyWith(talked: e.talked + 1, seen: e.seen + 1)
      else if (!turn.kind.aside)
        e.copyWith(seen: e.seen + 1)
      else
        e,
  ];

  /// [extras] with [found] added, the list kept to [maxExtras]: the
  /// least seen of the older ones make room, never the ones just met.
  static List<Extra> merge(List<Extra> extras, List<Extra> found) {
    final have = {for (final e in extras) e.name.toLowerCase()};
    final added = [
      for (final f in found)
        if (have.add(f.name.toLowerCase())) f,
    ];
    final room = maxExtras - added.length;
    var old = extras;
    if (old.length > room) {
      final keep = ([...old]..sort((a, b) => b.seen.compareTo(a.seen)))
          .take(room.clamp(0, maxExtras))
          .toSet();
      old = [
        for (final e in old)
          if (keep.contains(e)) e,
      ];
    }
    return [...old, ...added].take(maxExtras).toList();
  }

  /// The turns that mention [name], newest kept, up to [max] characters.
  static String excerpts(
    String name,
    List<StoryTurn> turns, {
    String playerName = 'The player',
    int max = 4000,
  }) {
    final out = <String>[];
    var size = 0;
    for (final t in turns.reversed) {
      if (t.kind.aside || !names(t.text, name)) continue;
      final who = switch (t.kind) {
        TurnKind.narrator => 'Narrator',
        TurnKind.character => t.speaker,
        TurnKind.ask => 'The human asks the narrator',
        _ => playerName,
      };
      final line = '$who: ${t.text}';
      if (size + line.length > max && out.isNotEmpty) break;
      out.add(line);
      size += line.length;
    }
    return out.reversed.join('\n\n');
  }

  /// What to ask [CharacterDescriber] for an extra's sheet.
  static String sheetIdea(Extra e, String excerpts) =>
      '${e.name}, ${e.line}. They are already in a story: keep their name and '
      'everything the story shows about them, and fill in the rest so it '
      'fits.\n\nWhat the story shows so far:\n$excerpts';

  /// The sheet part that holds what someone went through in the story.
  static const pastHeading = 'In this story';

  static const pastInstructions = '''
You keep notes for a roleplay story. In two to four short sentences, say
what this person went through in the story so far, what they did, and how
they stand with the player. Plain prose, no heading, nothing else.''';

  static String pastBrief(String name, String excerpts) =>
      'Person: $name\n\nWhat the story shows:\n$excerpts';
}
