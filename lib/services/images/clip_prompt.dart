import '../llm_client.dart';

/// "Write it for me": turns a few plain words about what should happen in a
/// clip into the kind of prompt a video model does well with, using the chat
/// model.
class ClipPrompt {
  const ClipPrompt._();

  /// How long a finished prompt may be; sd-cli prompts are cut at 2000.
  static const maxChars = 1500;

  /// The rules the chat model follows. [detailed] models (LTX) like a long,
  /// flowing description with sound; the others a short plain one.
  static String instructions({
    required bool detailed,
    int? seconds,
    String? model,
    int? chars,
  }) =>
      '''
You write prompts for an AI video model that animates one still picture.
The human gives you a few words about what should happen. Write the prompt.

${model == null ? '' : 'The video model is $model.\n'}${seconds == null ? '' : 'The clip is $seconds seconds long: ${pacing(seconds)}\n'}
Rules:
- Answer with the prompt only: no title, no quotes, no notes, no lists.
- Describe what MOVES, in the order it happens, in the present tense.
- Do not describe what the picture already shows (looks, clothes, room)
  beyond a few words to say who or what moves.
- Name small, believable motions (a blink, a breath, hair swaying, a
  head turn) rather than big sudden ones; one action at a time.
- Say how the camera behaves ("the camera stays still" if unsure).
${detailed ? '''- Write one flowing paragraph of about ${_words(chars, 160)} words.
- Then add what is heard: sounds in the room, and any words spoken, in
  double quotes, who says them and in what tone.''' : '''- Write one plain paragraph of about ${_words(chars, 60)} words.
- Do not write dialogue or sounds: this model makes silent clips.'''}
- Keep the human's wording for names and spoken words.
''';

  /// "min to max" words for a target length in characters (about six per
  /// word), falling back to [fallback] words in the middle.
  static String _words(int? chars, int fallback) {
    final mid = chars == null ? fallback : (chars / 6).round();
    return '${(mid * 0.8).round()} to ${(mid * 1.2).round()}';
  }

  /// How much can happen in [seconds]: a short clip holds one small motion,
  /// a long one a few in order.
  static String pacing(int seconds) => seconds <= 3
      ? 'one small action only, nothing else.'
      : seconds <= 6
      ? 'one main action and one small follow-up.'
      : seconds <= 10
      ? 'two or three actions one after another, each with room to finish.'
      : 'a short sequence of three or four actions, each clearly separate, '
            'and the camera may move slowly.';

  /// Strips what models add around a prompt: quotes, labels, thinking.
  static String? tidy(String reply, {int max = maxChars}) {
    var t = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    t = t.replaceFirst(
      RegExp(r'^(prompt|here is[^:\n]*)\s*:\s*', caseSensitive: false),
      '',
    );
    if (t.length > 1 && t.startsWith('"') && t.endsWith('"')) {
      t = t.substring(1, t.length - 1).trim();
    }
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    if (t.length < 20) return null;
    if (t.length > max) {
      final cut = t.lastIndexOf(RegExp(r'[.!?]'), max);
      t = t.substring(0, cut > 100 ? cut + 1 : max);
    }
    return t;
  }

  /// Asks [client] to write the prompt for [idea]; null if it gave nothing
  /// usable.
  static Future<String?> write(
    LlmClient client,
    String idea, {
    required bool detailed,
    int? seconds,
    String? model,
    int? chars,
    int? limit,
  }) async {
    final reply = StringBuffer();
    await for (final e in client.chat([
      {
        'role': 'system',
        'content': instructions(
          detailed: detailed,
          seconds: seconds,
          model: model,
          chars: chars,
        ),
      },
      {'role': 'user', 'content': idea.trim()},
    ])) {
      if (e is TextDelta) reply.write(e.text);
    }
    return tidy(reply.toString(), max: limit ?? maxChars);
  }
}
