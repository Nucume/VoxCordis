import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import '../../data/voces/voces_models.dart';

/// "Describe it": the human gives an idea in a few words, and the chat
/// model fills in a whole world (or character) from it, for them to
/// change as they like.

/// A world as the model filled it in.
class WorldDescription {
  const WorldDescription({
    required this.name,
    required this.line,
    required this.setting,
    required this.tags,
    this.opening,
  });

  final String name;
  final String line;
  final String setting;
  final List<String> tags;
  final Opening? opening;
}

/// A character as the model filled them in.
class CharacterDescription {
  const CharacterDescription({
    required this.name,
    required this.pronouns,
    required this.line,
    required this.traits,
    required this.sections,
  });

  final String name;
  final String pronouns;
  final String line;
  final List<String> traits;
  final List<SheetSection> sections;
}

class WorldDescriber {
  const WorldDescriber._();

  static String instructions({bool adult = false}) =>
      '''
You build worlds for a roleplay story library from a short idea.

Answer in exactly this shape and nothing else:
Name: <the world's name, one to four words>
Line: <the world in one sentence>
Tags: <one to ${WorldTags.max} tags, comma separated, from: ${[...WorldTags.all, if (adult) ...WorldTags.mature].join(', ')}>
Setting:
<two to four short paragraphs: where and when this is, what people
there want and fear, what kind of story it is and its tone, and any rules
the narrator should keep to>
Opening title: <two to five words>
Opening:
<the narrator's first words of a story here, 80 to 160 words, in the
second person and present tense>

Rules:
- The first tag is the main one: what stories here are mostly about.
- In the opening, never say who "you" are, what you look like, or what
  you say, think, feel or decide. End where the reader can act.
- Keep to the idea; fill in what it leaves open. No notes or lists.
''';

  static String brief(String idea, {bool adult = false}) =>
      ['Idea: ${idea.trim()}', if (adult) 'For adults (18+).'].join('\n');

  /// The world in [reply], or null when there's nothing usable.
  static WorldDescription? parse(String reply, {bool adult = false}) {
    final f = _fields(reply, const [
      'name',
      'line',
      'tags',
      'setting',
      'opening title',
      'opening',
    ]);
    final name = _oneLine(f['name'] ?? '');
    final setting = f['setting'] ?? '';
    if (name.isEmpty && setting.isEmpty) return null;
    final tags = WorldTags.only(
      (f['tags'] ?? '')
          .split(RegExp(r'[,;/\n]'))
          .map((w) => w.replaceAll(RegExp(r'[*"“”.]'), '').trim()),
    ).where((t) => adult || !WorldTags.mature.contains(t)).toList();
    final text = f['opening'] ?? '';
    final title = _oneLine(f['opening title'] ?? '');
    return WorldDescription(
      name: name.isEmpty ? 'Untitled world' : name,
      line: _oneLine(f['line'] ?? ''),
      setting: setting,
      tags: tags,
      opening: text.length < 40
          ? null
          : Opening(title.isEmpty ? 'Opening' : title, text),
    );
  }
}

class CharacterDescriber {
  const CharacterDescriber._();

  /// The parts of a sheet the model writes, in order.
  static const parts = [
    'Who they are',
    'Personality',
    'Looks',
    'How they talk',
  ];

  static const instructions = '''
You write character sheets for roleplay stories from a short idea.

Answer in exactly this shape and nothing else:
Name: <their name>
Pronouns: <e.g. she/her>
Line: <who they are, in one short sentence>
Traits: <three to six single words or short phrases, comma separated>
Who they are:
<their past and their place in the world, one short paragraph>
Personality:
<how they think and act, what they want and fear, one short paragraph>
Looks:
<how they look and dress, concrete details, one short paragraph>
How they talk:
<their voice and manner of speech, with one or two example lines>

Keep to the idea; fill in what it leaves open. No notes or lists beyond
the shape above.
''';

  static String brief(String idea) => 'Idea: ${idea.trim()}';

  /// The character in [reply], or null when there's nothing usable.
  static CharacterDescription? parse(String reply) {
    final f = _fields(reply, [
      'name',
      'pronouns',
      'line',
      'traits',
      for (final s in parts) s.toLowerCase(),
    ]);
    final name = _oneLine(f['name'] ?? '');
    final sections = [
      for (final s in parts)
        if ((f[s.toLowerCase()] ?? '').isNotEmpty)
          SheetSection(s, f[s.toLowerCase()]!),
    ];
    if (name.isEmpty && sections.isEmpty) return null;
    return CharacterDescription(
      name: name.isEmpty ? 'Unnamed' : name,
      pronouns: _oneLine(f['pronouns'] ?? ''),
      line: _oneLine(f['line'] ?? ''),
      traits: [
        for (final t in (f['traits'] ?? '').split(RegExp(r'[,;\n]')))
          if (t.replaceAll(RegExp(r'[*"“”.]'), '').trim() case final w
              when w.isNotEmpty)
            w,
      ].take(8).toList(),
      sections: sections,
    );
  }
}

/// Splits [reply] at lines that start with one of [labels] and a colon
/// ("Name: Ember Coast", "**Setting:**"), giving each label its text.
Map<String, String> _fields(String reply, List<String> labels) {
  final t = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
  // Longest first, so "opening title" isn't read as "opening".
  final sorted = [...labels]..sort((a, b) => b.length.compareTo(a.length));
  final head = RegExp(
    '^[#*\\s-]*(${sorted.map(RegExp.escape).join('|')})[*\\s]*:[*\\s]*(.*)\$',
    caseSensitive: false,
    multiLine: true,
  );
  final out = <String, String>{};
  final hits = head.allMatches(t).toList();
  for (var i = 0; i < hits.length; i++) {
    final m = hits[i];
    final end = i + 1 < hits.length ? hits[i + 1].start : t.length;
    final text = [
      m.group(2)!,
      t.substring(m.end, end),
    ].join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    out.putIfAbsent(m.group(1)!.toLowerCase(), () => text);
  }
  return out;
}

String _oneLine(String s) =>
    s.split('\n').first.replaceAll(RegExp(r'[*"“”]'), '').trim();

/// How big the chat model looks, in billions of parameters, from its file
/// or model name ("Rocinante-12B-Q4_K_M.gguf" → 12); null when the name
/// doesn't say.
double? modelBillions(AppSettings s) {
  final name = switch (s.llmMode) {
    LlmMode.builtIn => s.modelPath == null ? '' : p.basename(s.modelPath!),
    LlmMode.external => s.llmModel,
  };
  final m = RegExp(
    r'(?<![\d.])(\d+(?:\.\d+)?)\s*b(?![a-z])',
    caseSensitive: false,
  ).firstMatch(name);
  return m == null ? null : double.tryParse(m.group(1)!);
}

/// Below this, "Describe it" warns that a bigger model writes better.
const smallModelBillions = 12.0;
