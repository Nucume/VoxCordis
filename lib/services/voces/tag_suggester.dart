import '../../data/voces/voces_models.dart';

/// The ✨ by a world's tags: asks the chat model to pick up to three of
/// [WorldTags.all] from the world's line and setting.
class TagSuggester {
  const TagSuggester._();

  static String instructions({bool adult = false}) =>
      '''
You tag roleplay worlds for a library. Pick the tags that fit the world
best from this list, and no others:
${[...WorldTags.all, if (adult) ...WorldTags.mature].join(', ')}

Answer with one line and nothing else:
Tags: <one to ${WorldTags.max} tags from the list, comma separated>

The first tag is the main one: what the story is mostly about. The others
add flavour.
''';

  static String brief({
    required String name,
    required String line,
    required String setting,
  }) {
    final b = StringBuffer()..writeln('World: $name');
    if (line.trim().isNotEmpty) b.writeln('In one line: ${line.trim()}');
    final s = setting.trim();
    if (s.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Setting:')
        ..writeln(s.length > 3000 ? s.substring(0, 3000) : s);
    }
    return b.toString();
  }

  /// The listed tags in [reply], best first; empty when it had none.
  static List<String> parse(String reply, {bool adult = false}) {
    final t = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final m = RegExp(
      r'^[*\s-]*tags[*\s]*:[*\s]*(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(t);
    final words = (m?.group(1) ?? t)
        .split(RegExp(r'[,;/\n]'))
        .map((w) => w.replaceAll(RegExp(r'[*"“”.]'), '').trim());
    return WorldTags.only(
      words,
    ).where((t) => adult || !WorldTags.mature.contains(t)).toList();
  }
}
