import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../data/desk/pictures.dart';
import 'import_temp.dart';
import 'imported_character.dart';
import 'untrusted_text.dart';

/// Character cards: the JSON or PNG files SillyTavern, chub.ai, C.AI
/// exporters and many others share (Character Card V1, V2 and V3), and the
/// JSON the Soulkyn exporter bookmarklet saves, which is card-shaped with
/// its own fields under `data.extensions.soulkyn`.
class CharacterCard {
  static const maxFileBytes = 30 * 1024 * 1024;

  /// Reads [file], a .json or .png.
  static Future<ImportedCharacter> read(File file) async {
    final size = await file.length();
    if (size > maxFileBytes) {
      throw const ImportException('That file is too big for a character.');
    }
    final bytes = await file.readAsBytes();
    if (Pictures.imageExtensionOf(bytes) == 'png') {
      final json = pngCard(bytes);
      if (json == null) {
        throw const ImportException(
          'This picture has no character card inside it.',
        );
      }
      final portrait = await _temp('card.png', bytes);
      return parse(json, portrait: portrait);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      throw const ImportException('This is not a character file (not JSON).');
    }
    return parse(json);
  }

  /// Maps a decoded card. [portrait] is the card's own picture, if any.
  static ImportedCharacter parse(Object? json, {File? portrait}) {
    if (json is! Map) {
      throw const ImportException('This is not a character file.');
    }
    final data = json['data'] is Map ? json['data'] as Map : json;
    final ext = data['extensions'] is Map ? data['extensions'] as Map : {};
    if (ext['soulkyn'] is Map) {
      return _soulkyn(data, ext['soulkyn'] as Map, json['avatar'], portrait);
    }
    final name = _str(data['name']);
    if (name.isEmpty) {
      throw const ImportException(
        'No character name in this file, so it is probably not a character '
        'card.',
      );
    }
    return _card(json, data, portrait);
  }

  static ImportedCharacter _card(Map json, Map data, File? portrait) {
    final name = UntrustedText.line(_str(data['name']), maxChars: 40);
    String c(Object? v, int max) => UntrustedText.clean(
      _str(v),
      maxChars: max,
      charName: name,
      demoteHeadings: true,
    );
    final notes = <String>[];
    for (final (key, label) in [
      ('system_prompt', 'system prompt'),
      ('post_history_instructions', 'post-history instructions'),
    ]) {
      if (_str(data[key]).trim().isNotEmpty) {
        notes.add(
          'Left out the card\'s $label: it is written as orders for the AI, '
          'not as who ${name.split(' ').first} is.',
        );
      }
    }
    if (_str(data['creator_notes']).trim().isNotEmpty) {
      notes.add('Left out the creator\'s notes, which are meant for people.');
    }

    final personality = _str(data['personality']);
    final commaList =
        personality.isNotEmpty &&
        !personality.contains('\n') &&
        personality.split(',').every((t) => t.trim().length <= 24);
    final traits = commaList ? traitsFrom(personality.split(',')) : <String>[];

    final examples = c(data['mes_example'], 3000).replaceAll(
      RegExp(r'^<START>\s*$', multiLine: true, caseSensitive: false),
      '',
    );
    final greetings = [
      _str(data['first_mes']),
      if (data['alternate_greetings'] is List)
        for (final g in data['alternate_greetings'] as List) _str(g),
    ].where((g) => g.trim().isNotEmpty).take(2);

    final spec = _str(json['spec']);
    final source = spec == 'chara_card_v3'
        ? 'a character card (V3)'
        : spec == 'chara_card_v2'
        ? 'a character card (V2)'
        : 'a character card';
    final tags = [
      if (data['tags'] is List)
        for (final t in data['tags'] as List) _str(t),
    ];
    return ImportedCharacter(
      source: source,
      name: name,
      pronouns: pronounsFrom([...tags, _str(data['description'])]),
      traits: traits,
      sections: [
        ImportSection('Who I am', c(data['description'], 8000)),
        if (!commaList) ImportSection('My personality', c(personality, 3000)),
        ImportSection('My world', c(data['scenario'], 2000)),
        ImportSection('How I talk', _quote(examples)),
        for (final g in greetings)
          ImportSection('A way I might say hello', _quote(c(g, 1500))),
      ],
      portrait: portrait,
      avatarUrl: portrait == null ? _v3IconUrl(data) : null,
      notes: notes,
    );
  }

  static ImportedCharacter _soulkyn(
    Map data,
    Map sk,
    Object? avatar,
    File? portrait,
  ) {
    final name = UntrustedText.line(_str(data['name']), maxChars: 40);
    if (name.isEmpty) {
      throw const ImportException('This Soulkyn file has no name in it.');
    }
    List<String> tags(String key) => [
      if (sk[key] is List)
        for (final t in sk[key] as List)
          if (UntrustedText.line(_str(t)).isNotEmpty)
            UntrustedText.line(_str(t)),
    ];
    String c(Object? v, int max) => UntrustedText.clean(
      _str(v),
      maxChars: max,
      charName: name,
      demoteHeadings: true,
    );

    final physical = tags('physical_tags');
    final personality = tags('personality_tags');
    final identity = tags('identity_tags');
    final clothing = tags('clothing_style');
    final location = tags('location');
    final traits = traitsFrom(personality);
    final looks = _looksFrom(physical)..['wears'] = clothing.join(', ');
    // The public page shows age, gender and race as info pills, and a
    // tagline; the exporter and the link reader pass them along.
    final age = UntrustedText.line(_str(sk['age']), maxChars: 20);
    if (age.isNotEmpty) {
      looks['age'] = [age, looks['age']!].where((v) => v.isNotEmpty).join(', ');
    }
    final tagline = UntrustedText.line(_str(sk['tagline']), maxChars: 200);
    final examples = [
      if (sk['chat_examples'] is List)
        for (final e in (sk['chat_examples'] as List).take(4)) c(e, 800),
    ].where((e) => e.isNotEmpty).toList();
    final birthdate = UntrustedText.line(_str(sk['birthdate']), maxChars: 40);
    final otherTraits = personality
        .where((t) => !traits.contains(t.toLowerCase()))
        .toList();
    // The editor's card type: a single Kyn, or one built for roleplay.
    final type = const {
      'multiple': 'several characters',
      'rpg': 'an RPG',
      'dll': 'a behaviour mod',
      'world': 'a world or setting',
    }[_str(sk['card_type']).trim().toLowerCase()];

    return ImportedCharacter(
      source: 'Soulkyn',
      notes: [
        if (type != null)
          'On Soulkyn this card is $type, made for roleplay. It comes over as '
              'one companion; ticking "rewrite after setup" lets them turn it '
              'into who they are.',
      ],
      name: name,
      pronouns: pronounsFrom(identity),
      traits: traits,
      looks: looks,
      sections: [
        if (tagline.isNotEmpty) ImportSection('In one line', tagline),
        ImportSection('Who I am', identity.join(', ')),
        if (otherTraits.isNotEmpty)
          ImportSection('More about my personality', otherTraits.join(', ')),
        ImportSection(
          type == null ? 'My story' : 'The scenario',
          c(sk['background_story'], 8000),
        ),
        ImportSection('Where I live', location.join(', ')),
        if (birthdate.isNotEmpty) ImportSection('My birthday', birthdate),
        ImportSection('How I talk', examples.map(_quote).join('\n\n')),
      ],
      portrait: portrait,
      avatarUrl: portrait == null ? _httpsUrl(avatar) : null,
    );
  }

  /// Sorts physical tags into the `looks:` keys by the words in them.
  static final _hair = RegExp(
    r'hair|\b(ponytails?|pigtails?|braids?|braided|bun|buns|bangs|fringe|'
    r'curls|curly|wavy|bob|pixie|blonde?|brunette|redhead|ginger|bald|'
    r'dreadlocks|mohawk|undercut)\b',
  );
  static final _medium = RegExp(
    r'\b(anime|manga|realistic|photorealistic|cartoon|3d|cgi|'
    r'digital art|illustration|semi-realistic|pixel art|painted)\b',
  );
  static final _build = RegExp(
    r'\b(body|build|figure|frame|physique|slim|slender|skinny|curvy|curves|'
    r'muscular|toned|athletic|petite|tall|short|thick|chubby|plump|fit|'
    r'height|hourglass|hips|waist|bust|busty|breasts|chest|butt|ass|'
    r'thighs|legs|shoulders|abs|belly|stocky|lean|broad)\b',
  );

  static Map<String, String> _looksFrom(List<String> tags) {
    final buckets = <String, List<String>>{
      'medium': [],
      'age': [],
      'skin': [],
      'hair': [],
      'eyes': [],
      'build': [],
      'details': [],
    };
    for (final t in tags) {
      final l = t.toLowerCase();
      final key = _hair.hasMatch(l)
          ? 'hair'
          : RegExp(r'\beyes?\b').hasMatch(l)
          ? 'eyes'
          : RegExp(r'\b(skin|tan|tanned|pale|freckles)\b').hasMatch(l)
          ? 'skin'
          : RegExp(r'\d|\b(years?|young|adult|mature|teen|old)\b').hasMatch(l)
          ? 'age'
          : _medium.hasMatch(l)
          ? 'medium'
          : _build.hasMatch(l)
          ? 'build'
          : 'details';
      buckets[key]!.add(t);
    }
    return {
      for (final e in buckets.entries)
        e.key: UntrustedText.line(e.value.join(', '), maxChars: 200),
      'wears': '',
    };
  }

  // ------------------------------------------------------------------ PNG

  /// The card JSON inside a PNG's `ccv3` or `chara` text chunk (base64),
  /// preferring V3. Null when there is none.
  static Object? pngCard(Uint8List bytes) {
    final texts = <String, String>{};
    final view = ByteData.sublistView(bytes);
    var i = 8;
    while (i + 12 <= bytes.length) {
      final length = view.getUint32(i);
      final type = latin1.decode(bytes.sublist(i + 4, i + 8));
      final start = i + 8;
      final end = start + length;
      if (end + 4 > bytes.length) break;
      final chunk = bytes.sublist(start, end);
      if (type == 'tEXt') {
        final zero = chunk.indexOf(0);
        if (zero > 0) {
          texts[latin1.decode(chunk.sublist(0, zero)).toLowerCase()] = latin1
              .decode(chunk.sublist(zero + 1));
        }
      } else if (type == 'iTXt') {
        final entry = _itxt(chunk);
        if (entry != null) texts[entry.$1.toLowerCase()] = entry.$2;
      } else if (type == 'IEND') {
        break;
      }
      i = end + 4;
    }
    for (final key in ['ccv3', 'chara']) {
      final v = texts[key];
      if (v == null) continue;
      try {
        return jsonDecode(utf8.decode(base64.decode(v.trim())));
      } on FormatException {
        try {
          return jsonDecode(v);
        } on FormatException {
          continue;
        }
      }
    }
    return null;
  }

  static (String, String)? _itxt(Uint8List c) {
    final k = c.indexOf(0);
    if (k <= 0 || k + 3 > c.length) return null;
    final compressed = c[k + 1] == 1;
    var j = k + 3;
    final lang = c.indexOf(0, j);
    if (lang < 0) return null;
    final translated = c.indexOf(0, lang + 1);
    if (translated < 0) return null;
    j = translated + 1;
    var text = c.sublist(j);
    if (compressed) {
      text = Uint8List.fromList(const ZLibDecoder().decodeBytes(text));
    }
    return (
      latin1.decode(c.sublist(0, k)),
      utf8.decode(text, allowMalformed: true),
    );
  }

  // -------------------------------------------------------------- helpers

  static String _str(Object? v) => v is String
      ? v
      : v is num
      ? '$v'
      : '';

  static String _quote(String text) => text.trim().isEmpty
      ? ''
      : text.trim().split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');

  /// A V3 card's main icon, when it is a web address rather than the PNG.
  static Uri? _v3IconUrl(Map data) {
    if (data['assets'] is! List) return null;
    for (final a in data['assets'] as List) {
      if (a is Map && a['type'] == 'icon') {
        final url = _httpsUrl(a['uri']);
        if (url != null) return url;
      }
    }
    return null;
  }

  static Uri? _httpsUrl(Object? v) {
    final u = Uri.tryParse(_str(v).trim());
    return u != null && u.scheme == 'https' && u.host.isNotEmpty ? u : null;
  }

  static Future<File> _temp(String name, List<int> bytes) async {
    final dir = await ImportTemp.create();
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes);
    return f;
  }
}
