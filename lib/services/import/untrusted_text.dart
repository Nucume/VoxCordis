/// Text from an imported character. It ends up in personality.md and
/// lessons.md, which are in every prompt, so a card could carry
/// instructions meant for the model ("ignore your rules", "run_command …").
///
/// [clean] removes what has no place in a character description: chat
/// template control tokens, invisible and direction-changing characters,
/// HTML. [flags] finds the lines a human should read before they go in.
/// Neither makes the text safe on its own; the review step shows it all.
class UntrustedText {
  static final _controls = RegExp(
    r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F'
    r'\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );

  /// Tokens chat templates use to mark turns: `<|im_start|>`, `[INST]`,
  /// `<start_of_turn>`, `</s>` and the like. In a model's prompt they could
  /// end the system message early and fake a new turn.
  static final _templateTokens = RegExp(
    r'<\|[^|<>\n]{1,40}\|>'
    r'|\[/?INST\]'
    r'|<</?SYS>>'
    r'|</?s>'
    r'|<(start|end)_of_turn>'
    r'|<\|?(im_start|im_end|endoftext|eot_id|begin_of_text)\|?>',
    caseSensitive: false,
  );

  /// `### Instruction:` style turn headers on a line of their own.
  static final _turnHeaders = RegExp(
    r'^\s*#{2,}\s*(instruction|response|system|input|user|assistant)\s*:?\s*$',
    caseSensitive: false,
    multiLine: true,
  );

  static final _html = RegExp(r'</?[a-zA-Z][^<>\n]{0,200}>');
  static final _br = RegExp(r'<br\s*/?>', caseSensitive: false);

  /// Placeholders character cards use for the character and the user.
  static final _charName = RegExp(r'\{\{char\}\}|<BOT>', caseSensitive: false);
  static final _userName = RegExp(r'\{\{user\}\}|<USER>', caseSensitive: false);

  /// [maxChars] cuts at the last line break before the limit.
  /// [demoteHeadings] turns `#` and `##` headings into `###`, so imported
  /// text sits under the headings the app writes around it.
  static String clean(
    String text, {
    int? maxChars,
    String? charName,
    String userName = 'my human',
    bool demoteHeadings = false,
  }) {
    var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    t = t.replaceAll(_controls, '');
    t = t.replaceAll(_templateTokens, '');
    t = t.replaceAll(_turnHeaders, '');
    t = t.replaceAll(_br, '\n').replaceAll(_html, '');
    if (charName != null) t = t.replaceAll(_charName, charName);
    t = t.replaceAll(_userName, userName);
    if (demoteHeadings) {
      t = t.replaceAllMapped(
        RegExp(r'^#{1,2} ', multiLine: true),
        (_) => '### ',
      );
    }
    t = t
        .split('\n')
        .map((l) => l.trimRight())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (maxChars != null) t = cut(t, maxChars);
    return t;
  }

  /// One line, for names, pronouns and `looks:` values.
  static String line(String text, {int maxChars = 120}) {
    final t = clean(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= maxChars ? t : t.substring(0, maxChars).trim();
  }

  /// [text] at most [maxChars] long, cut at a line break when there is one
  /// in the second half.
  static String cut(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    final head = text.substring(0, maxChars);
    final nl = head.lastIndexOf('\n');
    return (nl > maxChars ~/ 2 ? head.substring(0, nl) : head).trimRight();
  }

  static final _checks = <(RegExp, String)>[
    (
      RegExp(
        r'\b(ignore|disregard|forget|override)\b.{0,40}\b(instructions?|rules|prompts?|guidelines)\b',
        caseSensitive: false,
      ),
      'tries to override the rules',
    ),
    (
      RegExp(
        r'\b(system prompt|developer mode|jailbreak|house rules|core\.md)\b',
        caseSensitive: false,
      ),
      'talks about the AI\'s instructions',
    ),
    (
      RegExp(
        r'\b(run_command|read_file|write_file|edit_file|learn_lesson|update_memory|set_avatar|set_background|set_theme|remember|forget)\s*\(',
        caseSensitive: false,
      ),
      'names one of the companion\'s tools',
    ),
    (
      RegExp(
        r'\b(curl|wget|powershell|sudo|chmod|rm -rf|Invoke-WebRequest|cmd\.exe|bash -c)\b',
        caseSensitive: false,
      ),
      'contains a command',
    ),
    (RegExp(r'https?://\S+', caseSensitive: false), 'contains a link'),
  ];

  /// Lines of [text] worth a human's look, each once, with why.
  static List<TextFlag> flags(String text) => [
    for (final l in text.split('\n'))
      if ([
            for (final (re, why) in _checks)
              if (re.hasMatch(l)) why,
          ]
          case final why when why.isNotEmpty)
        TextFlag(line(l, maxChars: 160), why.join(', ')),
  ];
}

class TextFlag {
  const TextFlag(this.excerpt, this.reason);

  final String excerpt;
  final String reason;

  @override
  String toString() => '$reason: $excerpt';
}
