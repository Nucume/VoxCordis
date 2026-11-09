import 'dart:math';

import '../../data/voces/lore_match.dart';
import '../../data/voces/story_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import 'content_rules.dart';
import 'living_cast.dart';
import 'story_notes.dart';

/// How often people come and go on their own.
enum Liveliness {
  calm('Calm', 0.05),
  normal('Normal', 0.12),
  busy('Busy', 0.25);

  const Liveliness(this.label, this.arrive);
  final String label;

  /// Chance, before a narrator turn, that someone arrives. Leaving is half
  /// as likely.
  final double arrive;
  double get leave => arrive / 2;

  static Liveliness byName(Object? n) =>
      values.where((l) => l.name == n).firstOrNull ?? normal;
}

/// What a story keeps besides its turns: who is here, where, and how the
/// story runs. Saved in the story's log.
class StoryState {
  const StoryState({
    this.present = const [],
    this.pinned = const {},
    this.place = '',
    this.liveliness = Liveliness.normal,
    this.chain = 2,
    this.extras = const [],
    this.notes = const StoryNotes(),
    this.notesAt = 0,
    this.rolls = const {},
  });

  /// What the story keeps track of; see [StoryNotes].
  final StoryNotes notes;

  /// The last turn the notes were brought up to date with.
  final int notesAt;

  /// Rolls for risky turns, by turn id.
  final Map<int, int> rolls;

  /// Cast in the scene, besides the player, by id.
  final List<String> present;

  /// Present cast who never leave on their own.
  final Set<String> pinned;
  final String place;
  final Liveliness liveliness;

  /// How many replies may follow each other before it's the human's turn
  /// again (0 to 4).
  final int chain;

  /// People the narrator brought in who have no sheet yet.
  final List<Extra> extras;

  static const maxChain = 4;

  StoryState copyWith({
    List<String>? present,
    Set<String>? pinned,
    String? place,
    Liveliness? liveliness,
    int? chain,
    List<Extra>? extras,
    StoryNotes? notes,
    int? notesAt,
    Map<int, int>? rolls,
  }) => StoryState(
    present: present ?? this.present,
    pinned: pinned ?? this.pinned,
    place: place ?? this.place,
    liveliness: liveliness ?? this.liveliness,
    chain: chain ?? this.chain,
    extras: extras ?? this.extras,
    notes: notes ?? this.notes,
    notesAt: notesAt ?? this.notesAt,
    rolls: rolls ?? this.rolls,
  );

  Map<String, Object?> toJson() => {
    'present': present,
    'pinned': pinned.toList(),
    'place': place,
    'liveliness': liveliness.name,
    'chain': chain,
    'extras': [for (final e in extras) e.toJson()],
    if (!notes.isEmpty) 'notes': notes.toJson(),
    if (notesAt > 0) 'notesAt': notesAt,
    if (rolls.isNotEmpty)
      'rolls': {for (final e in rolls.entries) '${e.key}': e.value},
  };

  static StoryState fromJson(Map<String, Object?> json) => StoryState(
    present: [
      for (final p in (json['present'] as List?) ?? const [])
        if (p is String) p,
    ],
    pinned: {
      for (final p in (json['pinned'] as List?) ?? const [])
        if (p is String) p,
    },
    place: json['place'] is String ? json['place']! as String : '',
    liveliness: Liveliness.byName(json['liveliness']),
    chain: json['chain'] is int
        ? (json['chain']! as int).clamp(0, maxChain)
        : 2,
    extras: [
      for (final e in (json['extras'] as List?) ?? const []) ?Extra.fromJson(e),
    ],
    notes: StoryNotes.fromJson(json['notes']),
    notesAt: json['notesAt'] is int ? json['notesAt']! as int : 0,
    rolls: {
      if (json['rolls'] case final Map r)
        for (final e in r.entries)
          if (int.tryParse('${e.key}') case final id?)
            if (e.value is int) id: e.value as int,
    },
  );
}

/// Someone joining or leaving the scene.
class CastChange {
  const CastChange(this.who, {required this.arrives});
  final VocesCharacter who;
  final bool arrives;

  /// The divider shown in the story.
  String get line => arrives ? '${who.name} arrives' : '${who.name} leaves';
}

/// One prompt for the model.
class StoryPrompt {
  const StoryPrompt(this.system, this.user, this.stop);
  final String system;
  final String user;

  /// Lines that start someone else's turn: the reply ends there.
  final List<String> stop;
}

/// Who says what next in a story, and what each of them is told. Pure:
/// no model and no files, so it can be tested.
///
/// A speaker is a character id, or null for the narrator.
class StoryEngine {
  StoryEngine(this.world, {required this.mature, Random? random})
    : _random = random ?? Random();

  final StoryWorld world;
  final bool mature;
  final Random _random;

  /// How much of the story so far goes into a prompt, in characters.
  static const window = 14000;

  /// How alike (cosine, Recall's EmbeddingGemma) a lore entry has to be to
  /// the last turns to come in without a key word, and how many at most.
  static const loreMinScore = 0.5;
  static const loreByMeaning = 4;

  VocesCharacter? get player => world.player;
  String get playerName => player?.name ?? world.story.playerName;

  /// Cast who can be voiced (everyone but the player).
  Iterable<VocesCharacter> get voices =>
      world.cast.values.where((c) => c.id != world.story.playerId);

  /// The cast the story starts with: [chosen] if given, else everyone in
  /// the world's cast, up to three.
  List<String> startingCast([List<String>? chosen]) => [
    for (final id in chosen ?? world.world.castIds.take(3))
      if (world.cast.containsKey(id) && id != world.story.playerId) id,
  ];

  String nameOf(String? id) =>
      id == null ? 'Narrator' : (world.cast[id]?.name ?? id);

  /// Who answers the human's [turn]: whom they named, else whoever spoke
  /// last, else the only one here, else the narrator. Doing something or
  /// asking the narrator goes to the narrator unless someone is named.
  String? whoAnswers(StoryTurn turn, List<StoryTurn> before, StoryState state) {
    if (turn.kind == TurnKind.ask) return null;
    final named = _named(turn.text, state.present);
    if (named != null) return named;
    if (turn.kind == TurnKind.act || onlyAction(turn.text)) return null;
    for (final t in before.reversed.take(4)) {
      if (t.kind.byHuman) continue;
      if (t.kind == TurnKind.character && state.present.contains(t.speakerId)) {
        return t.speakerId;
      }
      break;
    }
    if (state.present.length == 1) return state.present.single;
    return null;
  }

  /// Who goes next when the human lets the story run ("Continue"), after
  /// [turns]: a character after the narrator, the one who hasn't spoken
  /// longest; the narrator after a character.
  String? whoContinues(List<StoryTurn> turns, StoryState state) {
    final last = turns.lastWhereOrNull((t) => !t.kind.aside);
    if (last == null || state.present.isEmpty) return null;
    if (last.kind == TurnKind.narrator) {
      final named = _named(last.text, state.present);
      if (named != null) return named;
      return _quietest(turns, state.present);
    }
    return null;
  }

  /// Who speaks after [reply] by [speaker], within a chain: someone
  /// present that it names. Null ends the chain, as does a reply that
  /// turns to the player.
  String? chainsTo(String reply, String? speaker, StoryState state) {
    if (_turnsToPlayer(reply)) return null;
    return _named(reply, [
      for (final id in state.present)
        if (id != speaker) id,
    ]);
  }

  /// Rolled before a narrator turn: someone of the world's cast arrives, or
  /// someone here (not pinned) leaves.
  CastChange? rollChange(StoryState state) {
    final roll = _random.nextDouble();
    final away = [
      for (final c in voices)
        if (!state.present.contains(c.id)) c,
    ];
    if (away.isNotEmpty && roll < state.liveliness.arrive) {
      return CastChange(away[_random.nextInt(away.length)], arrives: true);
    }
    final here = [
      for (final id in state.present)
        if (!state.pinned.contains(id) && world.cast[id] != null)
          world.cast[id]!,
    ];
    if (here.isNotEmpty &&
        roll >= state.liveliness.arrive &&
        roll < state.liveliness.arrive + state.liveliness.leave) {
      return CastChange(here[_random.nextInt(here.length)], arrives: false);
    }
    return null;
  }

  /// What [speaker] is told for their next reply.
  StoryPrompt prompt(
    String? speaker,
    List<StoryTurn> turns,
    StoryState state, {
    CastChange? change,
    List<LoreEntry> byMeaning = const [],
  }) {
    final who = speaker == null ? null : world.cast[speaker];
    final w = world.world;
    final recent = turns.reversed
        .where((t) => t.kind != TurnKind.picture)
        .take(8)
        .map((t) => t.text)
        .join('\n');
    final lore = <LoreEntry>{
      for (final b in world.lorebooks) ...LoreMatch.match(recent, b.entries),
      ...byMeaning,
    };
    final here = [
      for (final id in state.present)
        if (world.cast[id] != null && id != speaker) world.cast[id]!,
    ];
    final system = StringBuffer();
    if (who == null) {
      system
        ..writeln(
          'You are the narrator of a roleplay story set in ${w.name}. The '
          'human plays $playerName.',
        )
        ..writeln(
          'Describe the world, the scene, and the people who have no voice '
          'of their own. Speak to the human in the second person ("you").',
        )
        ..writeln(
          w.narratorLed
              ? 'You run this whole game: invent the people, places and '
                    'events the story needs, and voice everyone without a '
                    'sheet of their own, their words in quotes in your '
                    'prose. Keep what you invent consistent: people keep '
                    'their names, looks and ways when they come back.'
              : 'People without a sheet (a guard, a passer-by) are yours to '
                    'voice briefly, their words in quotes in your prose.',
        )
        ..writeln(_playerLines)
        ..writeln(
          'Never speak, act, think or decide for $playerName: stop where '
          'they would act, and leave it to the human.',
        )
        ..writeln(
          'The cast below speak for themselves in their own turns: you may '
          'show what they do, but do not write what they say.',
        )
        ..writeln(
          'If the scene moves somewhere new, start your reply with a line '
          '"Place: <where>" and then the story.',
        )
        ..writeln('Write one to three paragraphs of vivid prose.');
    } else {
      system
        ..writeln(
          'You are ${who.name} in a roleplay story set in ${w.name}. Stay '
          'in character. The human plays $playerName.',
        )
        ..writeln(
          'Write only ${who.name}\'s next reply: what they say, with short '
          'actions in *asterisks*. Never speak, act or decide for '
          '$playerName or anyone else. One or two paragraphs.',
        )
        ..writeln(_playerLines)
        ..writeln()
        ..writeln('# ${who.name}')
        ..writeln(_sheet(who));
    }
    system.writeln();
    system.writeln('# The world');
    if (w.setting.trim().isNotEmpty) system.writeln(w.setting.trim());
    system.writeln(
      ContentRules.forStory(
        world: w,
        difficulty: world.story.difficulty,
        mature: mature,
      ),
    );
    if (state.place.isNotEmpty) system.writeln('Where: ${state.place}');
    system
      ..writeln()
      ..writeln('# $playerName (played by the human)');
    final p = player;
    if (p != null) {
      system.writeln(who == null ? _sheet(p) : _line(p));
    }
    if (here.isNotEmpty) {
      system
        ..writeln()
        ..writeln('# Also here');
      for (final c in here) {
        system.writeln('- ${_line(c)}');
      }
    }
    if (who == null && state.extras.isNotEmpty) {
      system
        ..writeln()
        ..writeln(
          '# People met so far (you voice them; keep them as they were)',
        );
      for (final e in state.extras) {
        system.writeln('- ${e.name}${e.line.isEmpty ? '' : ' - ${e.line}'}');
      }
    }
    if (!state.notes.isEmpty) {
      system
        ..writeln()
        ..writeln('# Story notes')
        ..writeln(state.notes.forPrompt(playerName));
    }
    if (lore.isNotEmpty) {
      system
        ..writeln()
        ..writeln('# Lore');
      for (final e in lore) {
        system.writeln('- ${e.title}: ${e.text.trim()}');
      }
    }

    final user = StringBuffer()
      ..writeln('The story so far:')
      ..writeln()
      ..writeln(transcript(turns));
    if (change != null) {
      user.writeln(
        change.arrives
            ? '(${change.who.name} arrives now: show them coming in. '
                  '${_line(change.who)})'
            : '(${change.who.name} leaves now: show them going.)',
      );
    }
    // The first reply after a rolled turn shows how it went.
    final last = turns.lastWhereOrNull((t) => !t.kind.aside);
    if (last != null && last.kind.byHuman) {
      if (state.rolls[last.id] case final n?) {
        user.writeln(Fortune.forPrompt(n, playerName));
      }
    }
    user.write('Now write ${nameOf(speaker)}\'s next reply.');

    final others = <String>[
      playerName,
      if (speaker != null) 'Narrator',
      for (final c in here) c.name,
    ];
    return StoryPrompt(system.toString().trim(), user.toString(), [
      for (final n in others.take(4)) '\n$n:',
    ]);
  }

  /// How the human writes $playerName's turns.
  String get _playerLines =>
      '$playerName\'s turns put what they say in "quotes" and what they do '
      'in *asterisks*, often both in one turn; words without either are '
      'what they say.';

  /// Whether [text] only does something: actions in *asterisks* and no
  /// words said, which goes to the narrator unless someone is named.
  static bool onlyAction(String text) {
    final t = text.trim();
    if (!t.contains('*') || RegExp('["“”]').hasMatch(t)) return false;
    return t.replaceAll(RegExp(r'\*[^*]*\*'), '').trim().isEmpty;
  }

  /// How long a story rests before opening it again starts with a recap.
  static const recapAfter = Duration(hours: 1);

  /// Whether opening a story with [turns] at [now] starts with "Previously
  /// on…": a story of some length, left for a while.
  ///
  /// The first time a story is opened after VoxCordis starts it does
  /// ([lastRecap] null); after that only when the story has rested for
  /// [recapAfter] and the last recap is as old.
  static bool wantsRecap(
    List<StoryTurn> turns,
    DateTime now, {
    DateTime? lastRecap,
  }) {
    final told = turns.where((t) => !t.kind.aside).toList();
    if (told.length < 6) return false;
    if (lastRecap == null) return true;
    return now.difference(told.last.ts) >= recapAfter &&
        now.difference(lastRecap) >= recapAfter;
  }

  /// What the narrator is asked for a "Previously on…": a short recap of
  /// the story so far, no new events.
  ({String system, String user}) recap(List<StoryTurn> turns) => (
    system:
        'You are the narrator of "${world.world.name}", a roleplay story. '
        'Write a "Previously on…" recap for $playerName, who is coming back '
        'to the story after a break: three to five sentences in the past '
        'tense, in your narrator\'s voice, about where things stand, who is '
        'around and what is unresolved. Only what happened; nothing new, no '
        'questions, no heading, no lists.',
    user: 'The story so far:\n\n${transcript(turns)}\n\nWrite the recap.',
  );

  /// [turns] in order, in parts that each fit [window] as a transcript: a
  /// long stretch (a chat brought in from Soulkyn) is read a part at a
  /// time.
  static List<List<StoryTurn>> parts(List<StoryTurn> turns) {
    final out = <List<StoryTurn>>[];
    var part = <StoryTurn>[];
    var size = 0;
    for (final t in turns) {
      if (t.kind == TurnKind.picture) continue;
      final n = t.text.length + 40;
      if (part.isNotEmpty && size + n > window) {
        out.add(part);
        part = [];
        size = 0;
      }
      part.add(t);
      size += n;
    }
    if (part.isNotEmpty) out.add(part);
    return out;
  }

  /// The story as lines, newest last, cut to [window] characters.
  String transcript(List<StoryTurn> turns) {
    final lines = <String>[];
    var size = 0;
    for (final t in turns.reversed) {
      if (t.kind == TurnKind.picture) continue;
      final line = switch (t.kind) {
        TurnKind.narrator => 'Narrator: ${t.text}',
        TurnKind.character => '${t.speaker}: ${t.text}',
        TurnKind.say => '$playerName: ${t.text}',
        TurnKind.act => '$playerName (does): ${t.text}',
        TurnKind.ask => '(The human asks the narrator: ${t.text})',
        TurnKind.scene => '[${t.text}]',
        TurnKind.picture => '',
      };
      if (size + line.length > window && lines.isNotEmpty) break;
      lines.add(line);
      size += line.length + 2;
    }
    return lines.reversed.join('\n\n');
  }

  /// [reply] without a "Name:" in front, nor anything after a line where
  /// someone else starts talking.
  String clean(String reply, String? speaker) {
    var text = reply.trim();
    final own = '${nameOf(speaker)}:';
    if (text.toLowerCase().startsWith(own.toLowerCase())) {
      text = text.substring(own.length).trim();
    }
    final names = {
      playerName,
      'Narrator',
      for (final c in world.cast.values) c.name,
    }..remove(nameOf(speaker));
    for (final n in names) {
      final at = text.indexOf(RegExp('\n${RegExp.escape(n)}:'));
      if (at >= 0) text = text.substring(0, at).trim();
    }
    return text;
  }

  /// A narrator reply split into a new place (from a "Place:" first line)
  /// and the story.
  static ({String? place, String text}) splitPlace(String reply) {
    final m = RegExp(
      r'^\s*\**place:?\**\s*:?\s*(.+?)\s*\**\s*(?:\n|$)',
      caseSensitive: false,
    ).firstMatch(reply);
    if (m == null) return (place: null, text: reply.trim());
    final place = m.group(1)!.replaceAll('*', '').trim();
    return (place: place, text: reply.substring(m.end).trim());
  }

  String _sheet(VocesCharacter c) {
    final b = StringBuffer(_line(c));
    for (final s in c.sections) {
      if (s.text.trim().isEmpty) continue;
      b
        ..writeln()
        ..writeln('## ${s.heading}')
        ..write(s.text.trim());
    }
    return b.toString();
  }

  String _line(VocesCharacter c) => [
    c.name,
    if (c.pronouns != null && c.pronouns!.isNotEmpty) '(${c.pronouns})',
    if (c.line.isNotEmpty) '- ${c.line}',
  ].join(' ');

  /// Recent story text to look up lore by meaning with: the last few
  /// turns, newest last.
  String recentText(List<StoryTurn> turns, {int count = 4}) => [
    for (final t in turns.reversed.take(count).toList().reversed)
      if (!t.kind.aside) t.text,
  ].join('\n');

  /// Every lore entry the story could use, switched on and not always in.
  List<LoreEntry> get loreEntries => [
    for (final b in world.lorebooks)
      for (final e in b.entries)
        if (e.enabled && !e.always) e,
  ];

  /// The first of [ids] whose name is in [text], as a whole word (first
  /// names count too).
  String? _named(String text, List<String> ids) {
    var best = -1;
    String? found;
    for (final id in ids) {
      final c = world.cast[id];
      if (c == null) continue;
      for (final n in {c.name, c.name.split(' ').first}) {
        if (n.trim().length < 2) continue;
        final m = RegExp(
          '(?<![\\p{L}\\p{N}])${RegExp.escape(n)}(?![\\p{L}\\p{N}])',
          unicode: true,
          caseSensitive: false,
        ).firstMatch(text);
        if (m != null && (best < 0 || m.start < best)) {
          best = m.start;
          found = id;
        }
      }
    }
    return found;
  }

  /// Whether [reply] ends on the player: a question to them or their name
  /// near the end.
  bool _turnsToPlayer(String reply) {
    final tail = reply.length > 240
        ? reply.substring(reply.length - 240)
        : reply;
    if (RegExp(
      '(?<![\\p{L}])${RegExp.escape(playerName.split(' ').first)}(?![\\p{L}])',
      unicode: true,
      caseSensitive: false,
    ).hasMatch(tail)) {
      return true;
    }
    return RegExp(r'\byou\b[^.!]*\?\W*$', caseSensitive: false).hasMatch(tail);
  }

  String? _quietest(List<StoryTurn> turns, List<String> ids) {
    final last = <String, int>{for (final id in ids) id: -1};
    for (var i = 0; i < turns.length; i++) {
      final s = turns[i].speakerId;
      if (turns[i].kind == TurnKind.character && last.containsKey(s)) {
        last[s!] = i;
      }
    }
    final order = ids.toList()..sort((a, b) => last[a]!.compareTo(last[b]!));
    return order.first;
  }
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (final e in reversed) {
      if (test(e)) return e;
    }
    return null;
  }
}
