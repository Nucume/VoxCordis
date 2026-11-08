import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/voces/story_log.dart';
import '../../features/voces/story_text.dart';
import 'story_engine.dart';

/// A story as one file to keep or share: HTML with its pictures inside, or
/// Markdown with its pictures copied beside it.
abstract final class StoryExport {
  /// Who said each turn, as shown in the story.
  static String _who(StoryTurn t, String player) => switch (t.kind) {
    TurnKind.narrator => '',
    TurnKind.character => t.speaker,
    TurnKind.say => player,
    TurnKind.act => '$player (does)',
    TurnKind.ask => 'You ask the narrator',
    TurnKind.scene || TurnKind.picture => '',
  };

  static String _text(StoryTurn t) => t.kind == TurnKind.narrator
      ? StoryEngine.splitPlace(t.text).text
      : t.text;

  static String _esc(String s) => const HtmlEscape().convert(s);

  /// One line of story text as HTML: *italics*, **bold**.
  static String _line(String line) => [
    for (final r in storyRuns(line))
      r.bold && r.italic
          ? '<em><strong>${_esc(r.text)}</strong></em>'
          : r.bold
          ? '<strong>${_esc(r.text)}</strong>'
          : r.italic
          ? '<em>${_esc(r.text)}</em>'
          : _esc(r.text),
  ].join();

  static String _paras(String text) => [
    for (final l in text.split('\n'))
      if (l.trim().isNotEmpty) '<p>${_line(l)}</p>',
  ].join('\n');

  /// The whole story as one HTML page; pictures from [folder] are put
  /// inside it, so the file stands alone.
  static Future<String> html({
    required String title,
    required String worldName,
    required String player,
    required List<StoryTurn> turns,
    required String folder,
  }) async {
    final body = StringBuffer();
    for (final t in turns) {
      switch (t.kind) {
        case TurnKind.scene:
          body.writeln('<div class="scene">${_esc(t.text)}</div>');
        case TurnKind.picture:
          final f = File(p.join(folder, t.text));
          if (!await f.exists()) continue;
          final ext = p.extension(f.path).replaceFirst('.', '').toLowerCase();
          final type = ext == 'jpg' ? 'jpeg' : ext;
          final data = base64Encode(await f.readAsBytes());
          body.writeln(
            '<figure><img src="data:image/$type;base64,$data" alt=""></figure>',
          );
        default:
          final who = _who(t, player);
          final cls = t.kind.byHuman
              ? 'you'
              : t.kind == TurnKind.narrator
              ? 'narrator'
              : 'cast';
          body.writeln(
            '<div class="turn $cls">'
            '${who.isEmpty ? '' : '<div class="who">${_esc(who)}</div>'}'
            '${_paras(_text(t))}</div>',
          );
      }
    }
    return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(title)}</title>
<style>
body { background: #111016; color: #e9e6f2; font: 17px/1.6 Georgia, serif; margin: 0; }
main { max-width: 760px; margin: 0 auto; padding: 40px 20px 80px; }
h1 { font-family: system-ui, sans-serif; margin: 0 0 4px; }
.world { color: #a29db3; font-family: system-ui, sans-serif; margin-bottom: 32px; }
.turn { margin: 18px 0; }
.turn p { margin: 0 0 8px; }
.who { font: 600 13px system-ui, sans-serif; color: #b9a5ff; margin-bottom: 2px; }
.cast { background: #1c1a24; border: 1px solid #2c2838; border-radius: 14px; padding: 10px 14px; }
.you { background: #241f36; border: 1px solid #3b3260; border-radius: 14px; padding: 10px 14px; margin-left: 15%; }
em { color: #b3adc4; }
.scene { text-align: center; color: #8d879d; font: 13px system-ui, sans-serif; margin: 22px 0; }
figure { margin: 22px 0; }
img { max-width: 100%; border-radius: 12px; }
</style>
</head>
<body><main>
<h1>${_esc(title)}</h1>
<div class="world">${_esc(worldName)}</div>
$body</main></body>
</html>
''';
  }

  /// The story as Markdown; pictures are named by their path under
  /// [pictures] (a folder beside the file).
  static String markdown({
    required String title,
    required String worldName,
    required String player,
    required List<StoryTurn> turns,
    String pictures = 'pictures',
  }) {
    final out = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('*$worldName*')
      ..writeln();
    for (final t in turns) {
      switch (t.kind) {
        case TurnKind.scene:
          out.writeln('---\n\n*${t.text}*\n');
        case TurnKind.picture:
          out.writeln('![]($pictures/${p.basename(t.text)})\n');
        default:
          final who = _who(t, player);
          if (who.isNotEmpty) out.writeln('**$who:**  ');
          out.writeln('${_text(t).trim()}\n');
      }
    }
    return out.toString();
  }
}
