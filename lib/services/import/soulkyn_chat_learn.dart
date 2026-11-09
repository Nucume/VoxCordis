import 'soulkyn_chat.dart';
import 'untrusted_text.dart';

/// Has the companion read an imported Soulkyn chat and keep what is worth
/// remembering as memories, part by part: a whole chat is far longer than
/// what a local model can read at once.
class SoulkynChatLearn {
  /// About how much chat one request reads.
  static const partChars = 9000;

  /// Most memories one part may give.
  static const perPart = 6;

  /// The chat as parts of at most [partChars], each a transcript with the
  /// Kyn as [companion] and the human as the name they went by.
  static List<String> parts(SoulkynChat chat, String companion) {
    final out = <String>[];
    final b = StringBuffer();
    for (final l in chat.lines) {
      var line = '${l.fromKyn ? companion : chat.persona}: ${l.text}';
      if (line.length > partChars) line = '${line.substring(0, partChars)}…';
      if (b.isNotEmpty && b.length + line.length + 2 > partChars) {
        out.add(b.toString());
        b.clear();
      }
      if (b.isNotEmpty) b.write('\n\n');
      b.write(line);
    }
    if (b.isNotEmpty) out.add(b.toString());
    return out;
  }

  static String instructions(String companion, String persona) =>
      '''
You are $companion. Below is part of an older chat between you and your
human, from another app; there your human went by "$persona". Pick out what
is worth remembering for a long time: who your human is, what they like and
dislike, what happened between you that matters, promises and plans, names
of people and places that keep coming up. Skip small talk and the moment to
moment of a scene.

Write each memory as one short sentence from your own point of view ("My
human loves rainy days", "We met at the campus pool"). At most $perPart, one
per line, each starting with "- ". If nothing is worth keeping, write
"- none". Nothing else: no heading, no comments.''';

  static String brief(String part, int index, int of) =>
      'Part ${index + 1} of $of of the chat:\n\n$part';

  /// The memories in [reply], cleaned; empty when it has none.
  static List<String> parse(String reply) {
    final t = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final out = <String>[];
    for (final raw in t.split('\n')) {
      final m = RegExp(r'^\s*(?:[-*•]|\d+[.)])\s+(.+)$').firstMatch(raw);
      if (m == null) continue;
      final line = UntrustedText.line(
        m.group(1)!.replaceAll('**', ''),
        maxChars: 300,
      ).trim();
      if (line.isEmpty || line.toLowerCase().replaceAll('.', '') == 'none') {
        continue;
      }
      if (line.length < 8) continue;
      out.add(line);
      if (out.length >= perPart) break;
    }
    return out;
  }

  /// Lowercased, without punctuation: to skip a memory already kept.
  static String key(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}
