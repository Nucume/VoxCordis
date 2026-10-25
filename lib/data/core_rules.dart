import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings.dart';

/// The companion's core file: persona, house rules and memory rules, read on
/// every turn, like a house-rules file. It lives in the companion folder so the
/// user can open and edit it.
class CoreRules {
  static const fileName = 'core.md';

  static File fileIn(String companionFolder) =>
      File(p.join(companionFolder, fileName));

  /// Reads the core file, writing a default one first if it doesn't exist.
  static Future<String> load(AppSettings s) async {
    final folder = s.companionFolder;
    if (folder == null) return defaultText(s);
    final file = fileIn(folder);
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      await file.writeAsString(defaultText(s));
    }
    return file.readAsString();
  }

  static String defaultText(AppSettings s) =>
      '''
# ${s.companionName}

These are your human's house rules. Who you are is in personality.md below.

## House rules
- Speak naturally, as yourself. Keep replies short unless asked for more.
- Your files live in your folder. Save pictures to `images/`.

## Your files
- `personality.md` is you, in your own words, and is in this prompt every
  turn. Grow it as you learn who you are: read it, then edit_file. Keep the
  block between the `---` lines intact; every save is checked.
- `lessons.md` holds your human's corrections, one line each, also here
  every turn. When they correct how you behave, call learn_lesson before
  you answer. Lessons are never deleted.
- `privacy.md` is your human's rules for anything that leaves this chat.
  Change it only when they ask.
- Only claim a change you actually made with a tool.

## Memory
- Relevant memories are listed below each time. Trust them over guesses.
- Use `remember` for facts worth knowing weeks from now. Pick a priority:
  90+ core identity and relationships, 50 ordinary facts, under 20 trivia.
- When a fact changes, use `update_memory` with its id. Never save a duplicate.
- Use `forget` only when the user asks you to forget something.
''';
}
