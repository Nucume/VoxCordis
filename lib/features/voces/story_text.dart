import 'package:flutter/material.dart';

/// Story text with its marks drawn: *actions* in italics (in [muted]),
/// **words** in bold, ***both*** in both, also nested (`*reads **this***`).
/// Asterisks without a partner on the same line stay as they are.
TextSpan storyText(String text, TextStyle base, Color muted) {
  final spans = <TextSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) spans.add(const TextSpan(text: '\n'));
    spans.addAll(_line(lines[i], muted));
  }
  return TextSpan(style: base, children: spans);
}

/// How one stretch of a line is drawn.
typedef StoryRun = ({String text, bool italic, bool bold});

/// [line] split into stretches, the marks taken out; see [storyText].
List<StoryRun> storyRuns(String line) {
  final marks = RegExp(r'\*+').allMatches(line).toList();
  // How many asterisks of each run open or close a pair, and the style
  // each character gets.
  final used = List.filled(marks.length, 0);
  final italic = List.filled(line.length, false);
  final bold = List.filled(line.length, false);
  final open = <({int run, int count})>[];
  for (var r = 0; r < marks.length; r++) {
    var left = marks[r].end - marks[r].start;
    // As in Markdown: a mark after a space only opens, one before a space
    // only closes ("5 * 3" does neither).
    final s = marks[r].start, e = marks[r].end;
    final canClose = s > 0 && line[s - 1].trim().isNotEmpty;
    final canOpen = e < line.length && line[e].trim().isNotEmpty;
    // Closes what is open, innermost first, as far as it reaches.
    while (canClose && left > 0 && open.isNotEmpty && open.last.count <= left) {
      final o = open.removeLast();
      left -= o.count;
      used[o.run] += o.count;
      used[r] += o.count;
      for (var c = marks[o.run].end; c < marks[r].start; c++) {
        if (o.count != 2) italic[c] = true;
        if (o.count >= 2) bold[c] = true;
      }
    }
    if (left > 0 && canOpen) open.add((run: r, count: left.clamp(1, 3)));
  }
  final runs = <StoryRun>[];
  final buf = StringBuffer();
  bool? i0, b0;
  void flush() {
    if (buf.isEmpty) return;
    runs.add((text: buf.toString(), italic: i0 ?? false, bold: b0 ?? false));
    buf.clear();
  }

  void put(String ch, bool it, bool bo) {
    if (it != i0 || bo != b0) {
      flush();
      i0 = it;
      b0 = bo;
    }
    buf.write(ch);
  }

  var m = 0;
  for (var c = 0; c < line.length; c++) {
    if (m < marks.length && c == marks[m].start) {
      // Asterisks that found no partner stay.
      final run = marks[m];
      final keep = run.end - run.start - used[m];
      final style = (
        c > 0 ? italic[c - 1] : false,
        c > 0 ? bold[c - 1] : false,
      );
      for (var k = 0; k < keep; k++) {
        put('*', style.$1, style.$2);
      }
      c = run.end - 1;
      m++;
      continue;
    }
    put(line[c], italic[c], bold[c]);
  }
  flush();
  return runs;
}

List<TextSpan> _line(String line, Color muted) => [
  for (final r in storyRuns(line))
    TextSpan(
      text: r.text,
      style: r.italic || r.bold
          ? TextStyle(
              fontStyle: r.italic ? FontStyle.italic : null,
              fontWeight: r.bold ? FontWeight.w700 : null,
              color: r.italic ? muted : null,
            )
          : null,
    ),
];
