import '../../data/voces/voces_models.dart';
import '../voces/sentence_words.dart';

/// One named person found in a card's scenario.
class ScenarioPerson {
  const ScenarioPerson(this.name, this.text);
  final String name;
  final String text;
}

/// A card's long scenario cut up for a narrator-led world: the start stays
/// in the world's setting (what the narrator always knows), the rest
/// becomes lore entries called up when the story touches them, and people
/// listed by name (under a heading like "Characters") become characters.
class ScenarioSplit {
  const ScenarioSplit({
    required this.setting,
    required this.entries,
    required this.people,
  });

  final String setting;
  final List<LoreEntry> entries;
  final List<ScenarioPerson> people;

  /// About how much of the scenario stays in the setting.
  static const settingChars = 1800;
  static const maxPeople = 12;
  static const maxEntries = 120;

  static ScenarioSplit of(String text, {bool manyPeople = false}) {
    final blocks = _blocks(text.replaceAll('\r\n', '\n').trim());
    final setting = StringBuffer();
    final entries = <LoreEntry>[];
    final people = <ScenarioPerson>[];
    final seen = <String>{};
    for (final b in blocks) {
      final castBlock =
          manyPeople ||
          (b.heading != null && _castHeading.hasMatch(b.heading!));
      if (castBlock) {
        final found = _people(b.body);
        for (final p in found) {
          if (people.length >= maxPeople) break;
          if (seen.add(p.name.toLowerCase())) people.add(p);
        }
        // A block that was only a list of people needs no lore entry too.
        if (found.isNotEmpty && _leftover(b.body, found).length < 80) {
          continue;
        }
      }
      final whole = b.heading == null ? b.body : '${b.heading}\n${b.body}';
      if (setting.length + whole.length <= settingChars ||
          setting.isEmpty && entries.isEmpty) {
        if (setting.isNotEmpty) setting.write('\n\n');
        setting.write(whole);
        continue;
      }
      if (entries.length >= maxEntries) continue;
      entries.add(
        LoreEntry(
          title: b.heading ?? _title(b.body),
          keys: _keys(b.heading, b.body),
          text: b.body,
        ),
      );
    }
    return ScenarioSplit(
      setting: setting.toString().trim(),
      entries: entries,
      people: people,
    );
  }

  static final _castHeading = RegExp(
    r'character|cast|npc|people|companion|who.?s who|residents|crew|'
    r'members|personas?',
    caseSensitive: false,
  );

  /// A heading line: markdown `#`, a whole bold line, or a short line in
  /// capitals or ending with a colon.
  static final _headingLine = RegExp(
    r'^\s*(?:#{1,6}\s+(.+?)\s*#*|\*\*([^*]{2,60})\*\*:?|__([^_]{2,60})__:?|'
    r'([A-Z][A-Z0-9 &/\x27-]{2,40}):?|([A-Z][^.!?:\n]{1,40}):)\s*$',
  );

  static List<({String? heading, String body})> _blocks(String text) {
    final out = <({String? heading, String body})>[];
    String? heading;
    final body = StringBuffer();
    void flush() {
      final b = body.toString().trim();
      if (b.isNotEmpty) out.add((heading: heading, body: b));
      body.clear();
    }

    final lines = text.split('\n');
    final hasHeadings = lines.any((l) => _headingLine.hasMatch(l));
    for (final line in lines) {
      final m = hasHeadings ? _headingLine.firstMatch(line) : null;
      if (m != null) {
        flush();
        heading = [
          for (var i = 1; i <= 5; i++) m.group(i),
        ].firstWhere((g) => g != null)!.trim();
        continue;
      }
      if (!hasHeadings && line.trim().isEmpty) {
        // No headings: each paragraph is a block, joined until a
        // reasonable size so the lore isn't a hundred scraps.
        if (body.length > 500) flush();
        body.write('\n');
        continue;
      }
      body.writeln(line);
    }
    flush();
    return out;
  }

  /// "Mira Vane: captain of …", "- **Tomas** (17) - a dockhand …".
  static final _personLine = RegExp(
    r'^\s*(?:[-*•]\s*)?\**([A-Z][\p{L}\x27’.-]+(?: [A-Z][\p{L}\x27’.-]+){0,2})'
    r'\**\s*(?:\([^)]{0,40}\))?\s*\**\s*[:–—-]\s*\**\s*(.{15,})$',
    unicode: true,
  );

  static const _notNames = {
    'note',
    'notes',
    'rules',
    'rule',
    'setting',
    'world',
    'story',
    'plot',
    'location',
    'locations',
    'goal',
    'goals',
    'tone',
    'style',
    'important',
    'warning',
    'scenario',
    'start',
    'ooc',
    'system',
    'narrator',
    'user',
    'the',
    'you',
    'example',
    'tip',
    'stats',
    'level',
    'hp',
    'quest',
  };

  static List<ScenarioPerson> _people(String body) => [
    for (final line in body.split('\n'))
      if (_personLine.firstMatch(line) case final m?)
        if (!_notNames.contains(m.group(1)!.toLowerCase()) &&
            !_notNames.contains(m.group(1)!.split(' ').first.toLowerCase()))
          ScenarioPerson(
            m.group(1)!.trim(),
            m.group(2)!.replaceAll('**', '').trim(),
          ),
  ];

  static String _leftover(String body, List<ScenarioPerson> found) => [
    for (final line in body.split('\n'))
      if (_personLine.firstMatch(line) == null) line,
  ].join('\n').trim();

  static String _title(String body) {
    final words = body
        .replaceAll(RegExp(r'[*#_]'), '')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(6)
        .join(' ');
    return words.length > 50 ? '${words.substring(0, 49)}…' : words;
  }

  /// The heading's words, and names said often in the body: capitalised
  /// words not at the start of a sentence.
  static List<String> _keys(String? heading, String body) {
    final keys = <String>[];
    if (heading != null) {
      final h = heading
          .replaceAll(RegExp(r'[^\p{L}\p{N} \x27-]', unicode: true), '')
          .trim();
      if (h.isNotEmpty && h.length <= 40) keys.add(h);
    }
    final counts = <String, int>{};
    for (final m in RegExp(
      r'(?<![.!?]\s)(?<!^)\b([A-Z][\p{L}\x27-]{2,}(?: [A-Z][\p{L}\x27-]{2,})?)',
      unicode: true,
      multiLine: true,
    ).allMatches(body)) {
      final w = m.group(1)!;
      if (sentenceWords.contains(w.split(' ').first)) continue;
      counts[w] = (counts[w] ?? 0) + 1;
    }
    final top = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in top.take(4)) {
      if (!keys.any((k) => k.toLowerCase() == e.key.toLowerCase())) {
        keys.add(e.key);
      }
    }
    return keys;
  }
}
