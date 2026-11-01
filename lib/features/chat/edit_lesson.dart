import '../../data/desk/desk_files.dart';
import '../../data/settings.dart';
import 'prompt_history.dart';

/// What the companion learns when its human rewrites one of its replies:
/// the model compares the reply with the rewrite and sums up, in one short
/// rule, what to do differently from now on. The human then keeps the rule
/// as a lesson, rewords it or skips it.
///
/// The request is small on purpose, so a small local model manages it: no
/// chat history and no tools, just the two versions (cut short when long)
/// and two lines to fill in.
class EditLesson {
  /// Most characters of each version the model is shown.
  static const maxShown = 1500;

  /// Most tokens the answer may take, with room for a model to think.
  static const maxTokens = 1200;

  /// Room the rule and its reason get in a lesson line, which is under
  /// [DeskFiles.lessonMaxChars] with its marks and date.
  static const maxRule = 90;
  static const maxWhy = 45;

  /// Whether the edit changed more than spacing, punctuation or letter
  /// case: a fixed comma teaches nothing.
  static bool worthLearning(String before, String after) {
    String words(String t) => t
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    return words(before) != words(after);
  }

  /// The request: the reply, the human's rewrite, and the message the reply
  /// answered when there is one.
  static List<Map<String, Object?>> prompt(
    AppSettings s, {
    required String before,
    required String after,
    String? asked,
  }) {
    final human = humanName(s);
    final name = s.companionName;
    return [
      {
        'role': 'system',
        'content':
            '$name is $human\'s AI companion. $human rewrote one of '
            '$name\'s replies. Compare the two versions and find what $human '
            'wants $name to do differently from now on: tone, length, style, '
            'wording, what to say or leave out.\n'
            'Answer with exactly two lines and nothing else:\n'
            'RULE: the rule for $name, at most 12 words, as an instruction, '
            'e.g. "Keep replies short and casual"\n'
            'WHY: why, at most 8 words\n'
            'If the rewrite only fixes a typo or a one-off detail that teaches '
            'nothing for later, answer only: NONE',
      },
      {
        'role': 'user',
        'content': [
          if (asked != null && asked.trim().isNotEmpty)
            '$human had said:\n${_cut(asked)}',
          '$name\'s reply:\n${_cut(before)}',
          '$human rewrote it as:\n${_cut(after)}',
          'What should $name learn?',
        ].join('\n\n'),
      },
    ];
  }

  static String _cut(String text) {
    final t = text.trim();
    return t.length <= maxShown ? t : '${t.substring(0, maxShown)}…';
  }

  static final _rule = RegExp(
    r'^[\s*_>#-]*rule[\s*_]*:[\s*_]*(.+)$',
    caseSensitive: false,
    multiLine: true,
  );
  static final _why = RegExp(
    r'^[\s*_>#-]*(?:why|reason)[\s*_]*:[\s*_]*(.+)$',
    caseSensitive: false,
    multiLine: true,
  );

  /// The rule and its reason from the model's answer; null for NONE or
  /// an answer without a rule.
  static ({String rule, String why})? parse(String answer) {
    final text = cutEndMark(answer).text;
    final rule = _rule.firstMatch(text)?.group(1);
    if (rule == null) return null;
    final r = _clean(rule, maxRule);
    if (r.isEmpty || RegExp(r'^none\b', caseSensitive: false).hasMatch(r)) {
      return null;
    }
    final why = _clean(_why.firstMatch(text)?.group(1) ?? '', maxWhy);
    return (rule: r, why: why.isEmpty ? 'my human rewrote my reply' : why);
  }

  /// One line without marks a lesson line can't hold, cut at a word.
  static String _clean(String text, int max) {
    var t = text
        .replaceAll('*', '')
        .replaceAll('—', '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    t = t.replaceAll(RegExp(r'^["“”\x27`]+|["“”\x27`]+$'), '').trim();
    if (t.endsWith('.')) t = t.substring(0, t.length - 1).trimRight();
    if (t.length <= max) return t;
    final cut = t.substring(0, max);
    final space = cut.lastIndexOf(' ');
    return (space > max ~/ 2 ? cut.substring(0, space) : cut).trimRight();
  }

  /// The edited message's content: [text] where the old words were, with
  /// the pictures and files [original] showed kept below it.
  static String withMarkersOf(String original, String text) {
    final markers = RegExp(
      r'^\[(?:image|file): [^\]\n]+\]$',
      multiLine: true,
    ).allMatches(original).map((m) => m[0]!).toList();
    return [
      text.trim(),
      markers.join('\n'),
    ].where((part) => part.isNotEmpty).join('\n\n');
  }
}
