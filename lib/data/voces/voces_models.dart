/// The building blocks of Voces Mundi, the roleplay mode: worlds, the
/// characters in them, lorebooks and stories (one playthrough of a world).
///
/// Each is a small JSON file in the Voces Mundi folder (see
/// [VocesLibrary]), so a world can be copied, shared or fixed by hand.
library;

/// A headed piece of a character sheet: "Who they are", "How they talk"…
class SheetSection {
  const SheetSection(this.heading, this.text);

  final String heading;
  final String text;

  Map<String, Object?> toJson() => {'heading': heading, 'text': text};

  static SheetSection fromJson(Map json) =>
      SheetSection(_s(json['heading']), _s(json['text']));
}

/// Someone who can be in a world: voiced by the AI, or played by the human
/// in a story. Who plays them is chosen per story, never here.
class VocesCharacter {
  const VocesCharacter({
    required this.id,
    required this.name,
    this.line = '',
    this.pronouns,
    this.tags = const [],
    this.sections = const [],
    this.portrait,
    this.art,
    this.source = '',
    this.created,
  });

  /// The folder name under `characters/`.
  final String id;
  final String name;

  /// One line saying who they are, shown in lists and used for the cast
  /// line of a prompt when they aren't the one speaking.
  final String line;
  final String? pronouns;
  final List<String> tags;
  final List<SheetSection> sections;

  /// A file name in the character's folder.
  final String? portrait;

  /// Seed of the colours shown when there's no portrait; picked at random
  /// when first saved, so no two look alike.
  final int? art;

  /// Where they came from, for people: "a character card (V2)", "Soulkyn",
  /// or empty when made here.
  final String source;
  final DateTime? created;

  /// Everything search looks through.
  String get searchText =>
      [name, line, ...tags, for (final s in sections) s.text].join(' ');

  VocesCharacter copyWith({
    String? id,
    String? name,
    String? line,
    String? pronouns,
    List<String>? tags,
    List<SheetSection>? sections,
    String? portrait,
    bool clearPortrait = false,
    int? art,
  }) => VocesCharacter(
    id: id ?? this.id,
    name: name ?? this.name,
    line: line ?? this.line,
    pronouns: pronouns ?? this.pronouns,
    tags: tags ?? this.tags,
    sections: sections ?? this.sections,
    portrait: clearPortrait ? null : portrait ?? this.portrait,
    art: art ?? this.art,
    source: source,
    created: created,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'name': name,
    'line': line,
    'pronouns': ?pronouns,
    'tags': tags,
    'sections': [for (final s in sections) s.toJson()],
    'portrait': ?portrait,
    'art': ?art,
    'source': source,
    'created': ?created?.toIso8601String(),
  };

  static VocesCharacter fromJson(Map json) => VocesCharacter(
    id: _s(json['id']),
    name: _s(json['name']),
    line: _s(json['line']),
    pronouns: json['pronouns'] as String?,
    tags: _strings(json['tags']),
    sections: [
      for (final s in _list(json['sections']))
        if (s is Map) SheetSection.fromJson(s),
    ],
    portrait: json['portrait'] as String?,
    art: (json['art'] as num?)?.toInt(),
    source: _s(json['source']),
    created: DateTime.tryParse(_s(json['created'])),
  );
}

/// One lorebook entry: text that joins the prompt when one of its key
/// words comes up in the story, or always.
class LoreEntry {
  const LoreEntry({
    required this.title,
    this.keys = const [],
    required this.text,
    this.always = false,
    this.enabled = true,
  });

  final String title;
  final List<String> keys;
  final String text;

  /// Always in the prompt (tone, house rules of the world).
  final bool always;
  final bool enabled;

  LoreEntry copyWith({
    String? title,
    List<String>? keys,
    String? text,
    bool? always,
    bool? enabled,
  }) => LoreEntry(
    title: title ?? this.title,
    keys: keys ?? this.keys,
    text: text ?? this.text,
    always: always ?? this.always,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'title': title,
    'keys': keys,
    'text': text,
    'always': always,
    'enabled': enabled,
  };

  static LoreEntry fromJson(Map json) => LoreEntry(
    title: _s(json['title']),
    keys: _strings(json['keys']),
    text: _s(json['text']),
    always: json['always'] == true,
    enabled: json['enabled'] != false,
  );
}

class Lorebook {
  const Lorebook({
    required this.id,
    required this.name,
    this.entries = const [],
    this.source = '',
  });

  /// The file name under `lorebooks/`, without `.json`.
  final String id;
  final String name;
  final List<LoreEntry> entries;
  final String source;

  Lorebook copyWith({String? id, String? name, List<LoreEntry>? entries}) =>
      Lorebook(
        id: id ?? this.id,
        name: name ?? this.name,
        entries: entries ?? this.entries,
        source: source,
      );

  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'name': name,
    'source': source,
    'entries': [for (final e in entries) e.toJson()],
  };

  static Lorebook fromJson(Map json) => Lorebook(
    id: _s(json['id']),
    name: _s(json['name']),
    source: _s(json['source']),
    entries: [
      for (final e in _list(json['entries']))
        if (e is Map) LoreEntry.fromJson(e),
    ],
  );
}

/// A way a story in a world can begin.
class Opening {
  const Opening(this.title, this.text);

  final String title;

  /// The narrator's first words.
  final String text;

  Map<String, Object?> toJson() => {'title': title, 'text': text};

  static Opening fromJson(Map json) =>
      Opening(_s(json['title']), _s(json['text']));
}

/// The tags a world can have: a fixed list, so the filters stay few and
/// worlds that are alike sit together. At most [max] per world.
abstract final class WorldTags {
  static const all = [
    'Fantasy',
    'Sci-fi',
    'Modern',
    'Historical',
    'Horror',
    'Mystery',
    'Romance',
    'Adventure',
    'Action',
    'Comedy',
    'Drama',
    'Slice of life',
    'Supernatural',
    'Post-apocalyptic',
    'Dark',
    'Cosy',
  ];

  /// More tags for 18+ worlds: not only lewd, also brutal or heavy.
  static const mature = [
    'Gore',
    'Brutal',
    'War',
    'Psychological',
    'Trauma',
    'Crime',
    'Sensual',
    'Kink',
  ];
  static const max = 3;

  /// What each tag means, and how a story led by it is told. Shown in the
  /// editor and given to the narrator word for word, so a tag means the
  /// same every time.
  static const meanings = <String, ({String means, String style})>{
    'Fantasy': (
      means: 'magic, myth and invented lands',
      style: 'wonder and rich, concrete detail; magic has rules and a cost',
    ),
    'Sci-fi': (
      means: 'future technology, space, or science pushed further',
      style: 'grounded in how the technology works and what it changes',
    ),
    'Modern': (
      means: 'the world of today',
      style: 'everyday, believable detail; people talk like real people',
    ),
    'Historical': (
      means: 'a real past era',
      style: 'true to the era\'s customs, objects and ways of speaking',
    ),
    'Horror': (
      means: 'fear, dread and things that should not be',
      style: 'dread over shock, slow reveals, short sentences when it hits',
    ),
    'Mystery': (
      means: 'a puzzle or secret to uncover',
      style: 'clues laid fairly, suspicion shifting, answers earned',
    ),
    'Romance': (
      means: 'love and attraction between characters',
      style: 'longing, small gestures and chemistry, a slow build',
    ),
    'Adventure': (
      means: 'journeys, exploration and daring',
      style: 'momentum, new places, risks taken for something worth it',
    ),
    'Action': (
      means: 'fights, chases and danger',
      style: 'quick, physical and clear; every action has a consequence',
    ),
    'Comedy': (
      means: 'humour and absurdity',
      style: 'timing, wit and characters who take themselves too seriously',
    ),
    'Drama': (
      means: 'relationships, conflict and hard choices',
      style: 'emotion carried by what people do and don\'t say',
    ),
    'Slice of life': (
      means: 'ordinary days and small moments',
      style: 'unhurried; small things matter',
    ),
    'Supernatural': (
      means: 'ghosts, spirits, curses or the uncanny in our world',
      style: 'the strange slipping into the ordinary',
    ),
    'Post-apocalyptic': (
      means: 'after the end of the world as it was',
      style: 'scarcity, ruins, and what people do to survive',
    ),
    'Dark': (
      means: 'a bleak, morally grey world',
      style: 'hard choices with no clean answers; hope is earned',
    ),
    'Cosy': (
      means: 'low stakes, warmth and small comforts',
      style: 'gentle, kind and comforting; trouble stays small',
    ),
    'Gore': (
      means: 'graphic wounds and bodies, shown up close',
      style: 'unflinching physical detail when violence happens',
    ),
    'Brutal': (
      means: 'cruel, merciless violence',
      style: 'relentless and visceral, Doom-style; enemies show no mercy',
    ),
    'War': (
      means: 'battles, sieges and what war does to people',
      style: 'the chaos of the front and the weight it leaves behind',
    ),
    'Psychological': (
      means: 'mind games, madness and manipulation',
      style: 'unreliable perceptions, tension, and the mind turning on itself',
    ),
    'Trauma': (
      means: 'abuse, grief and addiction',
      style: 'handled seriously and with weight, never for shock',
    ),
    'Crime': (
      means: 'cartels, torture and the underworld',
      style: 'loyalty, betrayal and violence with a price',
    ),
    'Sensual': (
      means: 'explicit intimacy that is romantic and slow-burning',
      style: 'desire built slowly; tenderness alongside explicit detail',
    ),
    'Kink': (
      means: 'explicit intimacy with fetishes and power play',
      style: 'consensual dynamics between the characters, shown explicitly',
    ),
  };

  /// "Horror: fear, dread and things that should not be", for prompts.
  static String describe(String tag) {
    final m = meanings[tag];
    return m == null ? tag : '$tag: ${m.means}';
  }

  /// Older names that now mean one of the tags above.
  static const _renamed = {
    'cozy': 'Cosy',
    'erotic': 'Sensual',
    'dark themes': 'Trauma',
  };

  /// The known tags among [tags], spelled as in [all], at most [max]. The
  /// first is the main tag.
  static List<String> only(Iterable<String> tags) {
    final picked = <String>[];
    for (final t in tags) {
      final key = t.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), ' ');
      final known =
          _renamed[key] ??
          [...all, ...mature]
              .where((k) => k.toLowerCase().replaceAll('-', ' ') == key)
              .firstOrNull;
      if (known != null && !picked.contains(known)) picked.add(known);
      if (picked.length == max) break;
    }
    return picked;
  }
}

/// A template for stories: the setting, who lives there, the lore and how
/// it can start. Stories take a copy when they begin, so editing a world
/// never changes a story already under way.
class VocesWorld {
  const VocesWorld({
    required this.id,
    required this.name,
    this.line = '',
    this.setting = '',
    this.tags = const [],
    this.adult = false,
    this.castIds = const [],
    this.lorebookIds = const [],
    this.openings = const [],
    this.picture,
    this.art,
    this.narratorLed = false,
    this.source = '',
    this.created,
  });

  final String id;
  final String name;

  /// One line for the world's card.
  final String line;

  /// Setting, tone and rules: what the narrator always knows.
  final String setting;

  /// Up to three of [WorldTags.all] (and [WorldTags.mature] in 18+
  /// worlds). The first is the main tag: the story revolves around it.
  final List<String> tags;

  /// Only for adults; shown as 18+ and kept apart from the tags.
  final bool adult;
  final List<String> castIds;
  final List<String> lorebookIds;
  final List<Opening> openings;
  final String? picture;

  /// Seed of the colours shown when there's no picture; picked at random
  /// when first saved, so no two worlds look alike.
  final int? art;

  /// Made from one card that runs the whole game: the narrator invents the
  /// people and places as the story goes.
  final bool narratorLed;
  final String source;
  final DateTime? created;

  String get searchText =>
      [name, line, setting, ...tags, if (adult) '18+'].join(' ');

  VocesWorld copyWith({
    String? id,
    String? name,
    String? line,
    String? setting,
    List<String>? tags,
    bool? adult,
    List<String>? castIds,
    List<String>? lorebookIds,
    List<Opening>? openings,
    String? picture,
    bool clearPicture = false,
    int? art,
    bool? narratorLed,
  }) => VocesWorld(
    id: id ?? this.id,
    name: name ?? this.name,
    line: line ?? this.line,
    setting: setting ?? this.setting,
    tags: tags ?? this.tags,
    adult: adult ?? this.adult,
    castIds: castIds ?? this.castIds,
    lorebookIds: lorebookIds ?? this.lorebookIds,
    openings: openings ?? this.openings,
    picture: clearPicture ? null : picture ?? this.picture,
    art: art ?? this.art,
    narratorLed: narratorLed ?? this.narratorLed,
    source: source,
    created: created,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'name': name,
    'line': line,
    'setting': setting,
    'tags': tags,
    'adult': adult,
    'cast': castIds,
    'lorebooks': lorebookIds,
    'openings': [for (final o in openings) o.toJson()],
    'picture': ?picture,
    'art': ?art,
    'narratorLed': narratorLed,
    'source': source,
    'created': ?created?.toIso8601String(),
  };

  static VocesWorld fromJson(Map json) => VocesWorld(
    id: _s(json['id']),
    name: _s(json['name']),
    line: _s(json['line']),
    setting: _s(json['setting']),
    tags: WorldTags.only(_strings(json['tags'])),
    adult:
        json['adult'] == true ||
        _strings(json['tags']).any((t) => t.trim() == '18+'),
    castIds: _strings(json['cast']),
    lorebookIds: _strings(json['lorebooks']),
    openings: [
      for (final o in _list(json['openings']))
        if (o is Map) Opening.fromJson(o),
    ],
    picture: json['picture'] as String?,
    art: (json['art'] as num?)?.toInt(),
    narratorLed: json['narratorLed'] == true,
    source: _s(json['source']),
    created: DateTime.tryParse(_s(json['created'])),
  );
}

/// How hard the world is on the human's character: consequences, wounds,
/// losses, and whether death is final. Chosen when a story starts.
enum Difficulty {
  kind('Kind', 'Setbacks sting but heal; the world leans your way.'),
  neutral('Neutral', 'Fair and fitting: choices matter, luck evens out.'),
  punishing('Punishing', 'Mistakes cost dearly; wounds and losses stay.'),
  grimdark(
    'Grimdark',
    'Bleak and merciless; death can be final. 18+ worlds only.',
  );

  const Difficulty(this.label, this.blurb);
  final String label;
  final String blurb;

  /// Only offered in 18+ worlds.
  bool get adultOnly => this == grimdark;

  static Difficulty byName(String? name) => switch (name) {
    // Stories saved while this was a moral lean.
    'grey' => neutral,
    'ruthless' => punishing,
    _ => values.firstWhere((d) => d.name == name, orElse: () => neutral),
  };
}

/// One playthrough of a world. Its folder holds a copy of the world, cast
/// and lorebooks as they were when it began; the chat itself lives in the
/// app's own (encrypted) storage.
class StorySave {
  const StorySave({
    required this.id,
    required this.title,
    required this.worldId,
    required this.worldName,
    required this.playerId,
    required this.playerName,
    this.difficulty = Difficulty.neutral,
    this.opening,
    required this.created,
    required this.lastPlayed,
    this.turns = 0,
    this.place = '',
  });

  final String id;
  final String title;
  final String worldId;
  final String worldName;

  /// The one character the human plays in this story. The AI never voices
  /// them here.
  final String playerId;
  final String playerName;
  final Difficulty difficulty;
  final String? opening;
  final DateTime created;
  final DateTime lastPlayed;
  final int turns;

  /// Where the story is now, for its card.
  final String place;

  StorySave copyWith({
    String? title,
    DateTime? lastPlayed,
    int? turns,
    String? place,
  }) => StorySave(
    id: id,
    title: title ?? this.title,
    worldId: worldId,
    worldName: worldName,
    playerId: playerId,
    playerName: playerName,
    difficulty: difficulty,
    opening: opening,
    created: created,
    lastPlayed: lastPlayed ?? this.lastPlayed,
    turns: turns ?? this.turns,
    place: place ?? this.place,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'title': title,
    'world': worldId,
    'worldName': worldName,
    'player': playerId,
    'playerName': playerName,
    'difficulty': difficulty.name,
    'opening': ?opening,
    'created': created.toIso8601String(),
    'lastPlayed': lastPlayed.toIso8601String(),
    'turns': turns,
    'place': place,
  };

  static StorySave fromJson(Map json) => StorySave(
    id: _s(json['id']),
    title: _s(json['title']),
    worldId: _s(json['world']),
    worldName: _s(json['worldName']),
    playerId: _s(json['player']),
    playerName: _s(json['playerName']),
    difficulty: Difficulty.byName(
      (json['difficulty'] ?? json['lean']) as String?,
    ),
    opening: json['opening'] as String?,
    created: DateTime.tryParse(_s(json['created'])) ?? DateTime(2000),
    lastPlayed: DateTime.tryParse(_s(json['lastPlayed'])) ?? DateTime(2000),
    turns: json['turns'] is int ? json['turns'] as int : 0,
    place: _s(json['place']),
  );
}

String _s(Object? v) => v is String ? v : '';

List<Object?> _list(Object? v) => v is List ? v : const [];

List<String> _strings(Object? v) => [
  for (final x in _list(v))
    if (x is String && x.trim().isNotEmpty) x.trim(),
];
