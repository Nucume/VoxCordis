import 'dart:convert';
import 'dart:io';

import '../../data/desk/pictures.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../voces/describer.dart';
import 'character_card.dart';
import 'imported_character.dart';
import 'scenario_split.dart';
import 'untrusted_text.dart';

/// What a dropped or picked file holds, for Voces Mundi: a character, a
/// lorebook, or both (a card with its own lorebook inside).
class VocesImported {
  const VocesImported({
    this.character,
    this.portrait,
    this.lorebook,
    this.notes = const [],
    this.card,
    this.world,
    this.cast = const [],
  });

  final VocesCharacter? character;

  /// The card as read, so it can still become a world instead
  /// ([VocesImport.asWorld]).
  final ImportedCharacter? card;

  /// A world the narrator runs, made from a card (with [cast] and
  /// [lorebook]); [portrait] is then its picture.
  final VocesWorld? world;
  final List<VocesCharacter> cast;

  /// Whether the card was made for roleplay rather than as one person
  /// (Soulkyn's RPG, World and Multiple cards).
  bool get looksLikeAGame =>
      const {'rpg', 'world', 'multiple'}.contains(card?.cardType);

  /// The card's own picture, still in a temporary folder.
  final File? portrait;
  final Lorebook? lorebook;

  /// What was left out or changed, for the human.
  final List<String> notes;

  bool get isEmpty => character == null && lorebook == null && world == null;
}

/// Reads character cards (V1–V3, JSON or PNG, and the Soulkyn exporter's
/// JSON) and lorebooks (a card's `character_book`, SillyTavern world info,
/// NovelAI lorebooks) into the Voces Mundi library.
///
/// All text goes through [UntrustedText] like the companion import: no
/// template tokens, no turn headers, no HTML. `{{user}}` stays as it is,
/// so a story can put the player's name in later.
class VocesImport {
  static const maxEntries = 500;
  static const maxEntryChars = 4000;

  /// Reads [file] and saves what it holds into [library].
  static Future<VocesImported> importFile(
    File file,
    VocesLibrary library,
  ) async {
    final read = await readFile(file);
    if (read.isEmpty) {
      throw const ImportException(
        'There is no character or lorebook in this file.',
      );
    }
    return save(read, library);
  }

  /// Saves [read] into [library]: the character with its portrait, and the
  /// lorebook named after them when the card brought one.
  static Future<VocesImported> save(
    VocesImported read,
    VocesLibrary library,
  ) async {
    var character = read.character;
    if (character != null) {
      character = await library.saveCharacter(character);
      final portrait = read.portrait;
      if (read.world == null && portrait != null && await portrait.exists()) {
        final name = await library.adoptPortrait(character.id, portrait);
        character = await library.saveCharacter(
          character.copyWith(portrait: name),
        );
      }
    }
    final cast = [for (final c in read.cast) await library.saveCharacter(c)];
    final book = read.lorebook == null
        ? null
        : await library.saveLorebook(read.lorebook!);
    var world = read.world;
    if (world != null) {
      world = await library.saveWorld(
        world.copyWith(
          castIds: [for (final c in cast) c.id],
          lorebookIds: [if (book != null) book.id],
        ),
      );
      final picture = read.portrait;
      if (picture != null && await picture.exists()) {
        final name = await library.adoptWorldPicture(world.id, picture);
        world = await library.saveWorld(world.copyWith(picture: name));
      }
    }
    return VocesImported(
      character: character,
      lorebook: book,
      notes: read.notes,
      world: world,
      cast: cast,
    );
  }

  /// [read]'s card as a world the narrator runs: its scenario's start is
  /// the setting, the rest a lorebook, people it lists by name characters.
  static VocesImported asWorld(VocesImported read) {
    final card = read.card!;
    String section(String heading) => card.sections
        .where((s) => s.heading == heading)
        .map((s) => s.text.trim())
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    // Soulkyn keeps the game in its story; other cards in the description
    // and the scenario.
    final soulkyn = card.source == 'Soulkyn';
    final scenario = [
      section('The scenario'),
      section('My story'),
      if (!soulkyn) section('Who I am'),
      section('My world'),
    ].where((t) => t.isNotEmpty).join('\n\n');
    final split = ScenarioSplit.of(
      scenario,
      manyPeople: card.cardType == 'multiple',
    );
    final where = section('Where I live');
    final about = section('Who I am');
    final setting = [
      split.setting,
      if (where.isNotEmpty) 'Places: $where',
      if (soulkyn && about.isNotEmpty && split.setting.isEmpty) about,
    ].join('\n\n').trim();
    final tagline = section('In one line');
    final cast = [
      for (final p in split.people)
        VocesCharacter(
          id: '',
          name: p.name,
          line: _firstSentence(p.text),
          sections: [SheetSection('Who they are', p.text)],
          source: '${card.source} (${card.name})',
          created: DateTime.now(),
        ),
    ];
    final world = VocesWorld(
      id: '',
      name: card.name,
      line: tagline.isNotEmpty ? tagline : _firstSentence(setting),
      setting: setting,
      narratorLed: true,
      openings: [
        if (section('A way I might say hello') case final hi when hi.isNotEmpty)
          Opening('From the card', hi),
      ],
      source: card.source,
      created: DateTime.now(),
    );
    final entries = [...split.entries, ...?read.lorebook?.entries];
    return VocesImported(
      world: world,
      cast: cast,
      portrait: read.portrait,
      lorebook: entries.isEmpty
          ? null
          : Lorebook(
              id: '',
              name: '${card.name} lore',
              entries: entries,
              source: 'imported',
            ),
      notes: [
        'It came in as a world the narrator runs: they invent and voice the '
            'people you meet.',
        if (entries.isNotEmpty)
          'The longer parts of its story went to the lorebook '
              '"${card.name} lore" (${entries.length} '
              '${entries.length == 1 ? 'entry' : 'entries'}), called up '
              'when the story touches them.',
        if (cast.isNotEmpty)
          '${cast.length == 1 ? 'One person it names' : '${cast.length} people it names'} '
              'went to Characters: ${cast.map((c) => c.name).join(', ')}.',
        'Check the 18+ switch and the tags in the world\'s editor.',
      ],
    );
  }

  static Future<VocesImported> readFile(File file) async {
    if (await file.length() > CharacterCard.maxFileBytes) {
      throw const ImportException('That file is too big to import.');
    }
    final bytes = await file.readAsBytes();
    if (Pictures.imageExtensionOf(bytes) == 'png') {
      final json = CharacterCard.pngCard(bytes);
      if (json == null) {
        throw const ImportException(
          'This picture has no character card inside it.',
        );
      }
      final card = await CharacterCard.read(file);
      return fromCard(json, card);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      throw const ImportException('This is not a card or lorebook (not JSON).');
    }
    if (json is! Map) {
      throw const ImportException('This is not a card or lorebook.');
    }
    if (isLorebook(json)) {
      final book = lorebook(json, fallbackName: _stem(file.path));
      return VocesImported(lorebook: book);
    }
    return fromCard(json, CharacterCard.parse(json));
  }

  /// A card's character, with its lorebook when it has one.
  static VocesImported fromCard(Object? json, ImportedCharacter card) {
    final data = json is Map && json['data'] is Map
        ? json['data'] as Map
        : json;
    final bookJson = data is Map ? data['character_book'] : null;
    final book = bookJson is Map
        ? lorebook(bookJson, fallbackName: '${card.name}\'s lore')
        : null;
    return VocesImported(
      card: card,
      character: character(card),
      portrait: card.portrait,
      lorebook: book == null || book.entries.isEmpty ? null : book,
      notes: [
        ...card.notes,
        if (book != null && book.entries.isNotEmpty)
          'Its lorebook (${book.entries.length} entries) went to Lorebooks.',
      ],
    );
  }

  /// The companion import writes in the first person ("Who I am"); a
  /// character in a world is talked about ("Who they are").
  static const _headings = {
    'Who I am': 'Who they are',
    'My personality': 'Personality',
    'More about my personality': 'Personality',
    'My world': 'Their world',
    'My story': 'Their story',
    'The scenario': 'The scenario',
    'Where I live': 'Where they live',
    'My birthday': 'Birthday',
    'How I talk': 'How they talk',
    'A way I might say hello': 'A way they might say hello',
    'In one line': 'In one line',
  };

  static VocesCharacter character(ImportedCharacter card) {
    final looks = [
      for (final e in card.looks.entries)
        if (e.value.trim().isNotEmpty) '- ${e.key}: ${e.value.trim()}',
    ].join('\n');
    final sections = <SheetSection>[
      for (final s in card.sections)
        if (s.text.trim().isNotEmpty && s.heading != 'In one line')
          SheetSection(_headings[s.heading] ?? s.heading, s.text.trim()),
      if (looks.isNotEmpty) SheetSection('Looks', looks),
    ];
    final tagline = card.sections
        .where((s) => s.heading == 'In one line')
        .map((s) => s.text.trim())
        .firstOrNull;
    return VocesCharacter(
      id: '',
      name: card.name,
      line: tagline ?? _firstSentence(sections.firstOrNull?.text ?? ''),
      pronouns: card.pronouns,
      tags: card.traits,
      looksTags: looksTagsOf(card.looks),
      sections: sections,
      source: card.source,
      created: DateTime.now(),
    );
  }

  /// Picture tags from a card's looks, when they came as tags (Soulkyn's
  /// physical tags and clothing): every part short, no sentences. A card
  /// that describes looks in prose gives none; "From Looks" in the editor
  /// makes them then.
  static List<String> looksTagsOf(Map<String, String> looks) {
    final out = <String>[];
    for (final e in looks.entries) {
      if (e.key == 'age' || e.key == 'medium') continue;
      for (final raw in e.value.split(',')) {
        final t = raw.trim().toLowerCase();
        if (t.isEmpty) continue;
        if (t.split(' ').length > 4 || t.contains('.')) return const [];
        if (!out.contains(t)) out.add(t);
      }
    }
    return out.take(LooksTags.max).toList();
  }

  /// Whether [json] is a lorebook on its own rather than a character card.
  static bool isLorebook(Map json) {
    if (json['data'] is Map || json['spec'] is String) return false;
    // A V1 card keeps its fields at the top.
    if (json['first_mes'] != null || json['description'] is String) {
      return false;
    }
    final entries = json['entries'];
    return entries is List || entries is Map;
  }

  /// Reads any of the common lorebook shapes:
  /// - a card's `character_book`: `entries: [{keys, content, constant, enabled, name|comment}]`
  /// - SillyTavern world info: `entries: {"0": {key, content, constant, disable, comment}}`
  /// - NovelAI: `entries: [{displayName, text, keys, enabled}]`
  static Lorebook lorebook(Map json, {String fallbackName = 'Lorebook'}) {
    final raw = json['entries'];
    final list = raw is List
        ? raw
        : raw is Map
        ? raw.values.toList()
        : const [];
    final entries = <LoreEntry>[];
    for (final e in list) {
      if (e is! Map || entries.length >= maxEntries) continue;
      final text = UntrustedText.clean(
        _str(e['content'] ?? e['text']),
        maxChars: maxEntryChars,
        userName: '{{user}}',
      ).trim();
      if (text.isEmpty) continue;
      final keys = [
        for (final k in [..._list(e['keys']), ..._list(e['key'])])
          if (UntrustedText.line(_str(k), maxChars: 60).isNotEmpty)
            UntrustedText.line(_str(k), maxChars: 60),
      ];
      final title = UntrustedText.line(
        _str(e['name'] ?? e['comment'] ?? e['displayName']),
        maxChars: 80,
      );
      entries.add(
        LoreEntry(
          title: title.isNotEmpty
              ? title
              : keys.isNotEmpty
              ? keys.first
              : _firstSentence(text, max: 40),
          keys: keys.toSet().toList(),
          text: text,
          always: e['constant'] == true,
          enabled: e['enabled'] != false && e['disable'] != true,
        ),
      );
    }
    final name = UntrustedText.line(_str(json['name']), maxChars: 60);
    return Lorebook(
      id: '',
      name: name.isEmpty ? fallbackName : name,
      entries: entries,
      source: 'imported',
    );
  }

  static String _firstSentence(String text, {int max = 120}) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final end = t.indexOf(RegExp(r'[.!?](\s|$)'));
    final s = end > 0 ? t.substring(0, end + 1) : t;
    return s.length <= max ? s : '${s.substring(0, max - 1).trim()}…';
  }

  static String _stem(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static List<Object?> _list(Object? v) => v is List
      ? v
      : v is String
      ? v.split(',')
      : const [];

  static String _str(Object? v) => v is String
      ? v
      : v is num
      ? '$v'
      : '';
}
