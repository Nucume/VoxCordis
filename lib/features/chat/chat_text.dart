import 'package:flutter/material.dart';

/// The light Markdown that chat models write: **bold**, *actions* (italic,
/// tinted), ***both***, ~~strike~~, `code`, `# headings` and `- bullets`.
/// A marker only counts when it has a partner on the same line, so a half
/// streamed "*smiles" stays as typed until its closing star arrives.
TextSpan formatChat(
  String text, {
  required Color actionColor,
  Color codeFill = const Color(0x22FFFFFF),
}) {
  final lines = text.split('\n');
  final spans = <InlineSpan>[];
  for (var n = 0; n < lines.length; n++) {
    if (n > 0) spans.add(const TextSpan(text: '\n'));
    var line = lines[n];
    var heading = false;
    final h = RegExp(r'^#{1,6}\s+').firstMatch(line);
    if (h != null) {
      heading = true;
      line = line.substring(h.end);
    }
    final b = RegExp(r'^(\s*)[-*+]\s+').firstMatch(line);
    if (b != null) {
      spans.add(TextSpan(text: '${b.group(1)}•  '));
      line = line.substring(b.end);
    }
    spans.addAll(
      _inline(
        line,
        actionColor: actionColor,
        codeFill: codeFill,
        bold: heading,
      ),
    );
  }
  return TextSpan(children: spans);
}

List<InlineSpan> _inline(
  String line, {
  required Color actionColor,
  required Color codeFill,
  bool bold = false,
}) {
  final out = <InlineSpan>[];
  final buf = StringBuffer();
  var boldOn = false, italic = false, strike = false;

  void flush() {
    if (buf.isEmpty) return;
    out.add(
      TextSpan(
        text: buf.toString(),
        style: TextStyle(
          fontWeight: bold || boldOn ? FontWeight.w700 : null,
          fontStyle: italic ? FontStyle.italic : null,
          color: italic ? actionColor : null,
          decoration: strike ? TextDecoration.lineThrough : null,
        ),
      ),
    );
    buf.clear();
  }

  bool spaceAt(int i) => i < 0 || i >= line.length || line[i].trim().isEmpty;

  // A closing run of [ch] somewhere after [from], right after a non-space.
  bool closerAfter(int from, String ch) {
    for (var j = from; j < line.length; j++) {
      if (line[j] == ch && !spaceAt(j - 1)) return true;
    }
    return false;
  }

  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == r'\' && i + 1 < line.length && r'*_`~\'.contains(line[i + 1])) {
      buf.write(line[i + 1]);
      i += 2;
      continue;
    }
    if (c == '`') {
      final end = line.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        out.add(
          TextSpan(
            text: line.substring(i + 1, end),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: codeFill,
            ),
          ),
        );
        i = end + 1;
        continue;
      }
    }
    if (c == '~' && line.startsWith('~~', i)) {
      if (strike && !spaceAt(i - 1)) {
        flush();
        strike = false;
        i += 2;
        continue;
      }
      if (!strike && !spaceAt(i + 2) && line.indexOf('~~', i + 3) > 0) {
        flush();
        strike = true;
        i += 2;
        continue;
      }
    }
    if (c == '*') {
      var run = 1;
      while (i + run < line.length && line[i + run] == '*') {
        run++;
      }
      final closes =
          !spaceAt(i - 1) &&
          ((run >= 3 && boldOn && italic) ||
              (run == 2 && boldOn) ||
              (run == 1 && italic));
      if (closes) {
        flush();
        if (run >= 3) {
          boldOn = italic = false;
        } else if (run == 2) {
          boldOn = false;
        } else {
          italic = false;
        }
        i += run;
        continue;
      }
      if (run <= 3 && !spaceAt(i + run) && closerAfter(i + run + 1, '*')) {
        flush();
        if (run != 1) boldOn = true;
        if (run != 2) italic = true;
        i += run;
        continue;
      }
      buf.write('*' * run);
      i += run;
      continue;
    }
    buf.write(c);
    i++;
  }
  flush();
  return out;
}
