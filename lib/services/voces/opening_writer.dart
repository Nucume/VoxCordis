import '../../data/voces/voces_models.dart';

/// "Write one for me" in a world's openings: asks the chat model for a way
/// a story there could begin, from what the world already says.
class OpeningWriter {
  const OpeningWriter._();

  /// The rules the chat model follows.
  static const instructions = '''
You write openings for a roleplay story. An opening is the narrator's first
words: it sets the scene the story begins in.

Rules:
- Answer in exactly this shape and nothing else:
  Title: <two to five words>

  <the opening>
- Write the opening in the second person ("you"), in the present tense, as
  the narrator, in 80 to 180 words.
- The person reading plays one character, who may be anyone: never say who
  "you" are, what you look like, or what you say, think, feel or decide.
- Set a clear place and moment, with something happening or about to, and
  end where the reader can act.
- Characters from the cast may appear and speak, true to their line.
- Keep to the world's setting and tags. No notes, no lists, no
  questions to the reader about what to do.
''';

  /// What the model is told about [world] and its [cast], plus the
  /// openings it already has (to write a different one) and [idea], the
  /// human's own words for this one, if any.
  static String brief({
    required VocesWorld world,
    required List<VocesCharacter> cast,
    String idea = '',
  }) {
    final b = StringBuffer()..writeln('World: ${world.name}');
    if (world.line.isNotEmpty) b.writeln('In one line: ${world.line}');
    if (world.tags.isNotEmpty) b.writeln('Tags: ${world.tags.join(', ')}');
    if (world.adult) b.writeln('For adults (18+).');
    if (world.setting.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Setting:')
        ..writeln(_cut(world.setting, 3000));
    }
    if (cast.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Cast:');
      for (final c in cast.take(12)) {
        b.writeln('- ${c.name}${c.line.isEmpty ? '' : ': ${c.line}'}');
      }
    }
    if (world.openings.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Openings it already has (write a different one):');
      for (final o in world.openings) {
        b.writeln('- ${o.title}: ${_cut(o.text, 160)}');
      }
    }
    b
      ..writeln()
      ..writeln(
        idea.trim().isEmpty
            ? 'Write a new opening.'
            : 'Write a new opening about: ${idea.trim()}',
      );
    return b.toString();
  }

  /// The title and opening in [reply], or null when there's nothing usable.
  static Opening? parse(String reply) {
    var t = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    String? title;
    final m = RegExp(
      r'^\**\s*title\s*\**\s*:\s*(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(t);
    if (m != null) {
      title = m.group(1)!.replaceAll(RegExp(r'[*"“”]'), '').trim();
      t = (t.substring(0, m.start) + t.substring(m.end)).trim();
    }
    t = t
        .replaceFirst(
          RegExp(r'^\**\s*opening\s*\**\s*:\s*', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (t.length > 1 && t.startsWith('"') && t.endsWith('"')) {
      t = t.substring(1, t.length - 1).trim();
    }
    if (t.length < 40) return null;
    if (title == null || title.isEmpty) {
      title = 'Opening';
    } else if (title.length > 48) {
      title = '${title.substring(0, 48).trimRight()}…';
    }
    return Opening(title, _cut(t, 2400));
  }

  static String _cut(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max).trimRight()}…';
}
