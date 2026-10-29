import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// [text] without leading blank lines, and with every run of blank lines
/// cut to one. Some models write dozens of empty lines (often right after
/// thinking), which would leave a reply bubble mostly blank. Fenced code
/// blocks are left exactly as written.
String tidyBlankLines(String text) {
  final out = StringBuffer();
  final parts = _scan(text);
  for (var n = 0; n < parts.length; n++) {
    final raw = (n > 0 ? '\n' : '') + parts[n].raw;
    out.write(parts[n].code ? raw : raw.replaceAll(_blankRun, '\n\n'));
  }
  return out.toString().replaceFirst(_leadingBlank, '');
}

/// One stretch of a message: plain chat text, a fenced code block, a table,
/// or a question with buttons to pick from.
class ChatBlock {
  const ChatBlock(
    this.text, {
    this.code = false,
    this.lang = '',
    this.rows,
    this.choices,
  });

  /// For code, just the code; the fences are gone.
  final String text;
  final bool code;

  /// The word after the opening fence, e.g. "python"; usually empty.
  final String lang;

  /// A table: the header row first. Null for anything else.
  final List<List<String>>? rows;

  /// The options of a ```choices block. Null for anything else.
  final List<String>? choices;
}

/// The fence word that makes a block into buttons.
const choicesFence = 'choices';

/// [text] cut into prose, tables and fenced ``` code blocks. A fence that is
/// still open (the reply is streaming) shows as a code block already; one
/// that will become buttons is held back until it closes.
List<ChatBlock> chatBlocks(String text) {
  final out = <ChatBlock>[];
  for (final p in _scan(text)) {
    if (p.code) {
      if (p.lang.toLowerCase() == choicesFence) {
        if (!p.closed) continue;
        final options = [
          for (final l in p.body.split('\n'))
            l.replaceFirst(RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+'), '').trim(),
        ].where((l) => l.isNotEmpty).take(8).toList();
        if (options.isNotEmpty) {
          out.add(ChatBlock('', choices: options));
          continue;
        }
      }
      out.add(ChatBlock(p.body, code: true, lang: p.lang));
    } else {
      final t = p.body.replaceAll(RegExp(r'^\n+|\n+$'), '');
      if (t.trim().isNotEmpty) out.addAll(_tables(t));
    }
  }
  return out;
}

final _tableRule = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');

List<String> _cells(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  return [for (final c in t.split(RegExp(r'(?<!\\)\|'))) c.trim()];
}

/// Pipe tables out of prose; the rest stays prose.
List<ChatBlock> _tables(String text) {
  final lines = text.split('\n');
  final out = <ChatBlock>[];
  final prose = <String>[];
  void flushProse() {
    if (prose.isEmpty) return;
    final t = prose.join('\n');
    if (t.trim().isNotEmpty) out.add(ChatBlock(t));
    prose.clear();
  }

  var i = 0;
  while (i < lines.length) {
    if (i + 1 < lines.length &&
        lines[i].contains('|') &&
        lines[i + 1].contains('|') &&
        _tableRule.hasMatch(lines[i + 1])) {
      final header = _cells(lines[i]);
      final rows = [header];
      var j = i + 2;
      while (j < lines.length && lines[j].contains('|')) {
        final row = _cells(lines[j]);
        // Ragged rows are padded or cut to the header's width.
        rows.add([
          for (var c = 0; c < header.length; c++) c < row.length ? row[c] : '',
        ]);
        j++;
      }
      flushProse();
      out.add(ChatBlock('', rows: rows));
      i = j;
      continue;
    }
    prose.add(lines[i]);
    i++;
  }
  flushProse();
  return out;
}

class _Part {
  _Part(this.code, this.raw, this.body, [this.lang = '', this.closed = true]);
  final bool code;
  final String raw;
  final String body;
  final String lang;
  final bool closed;
}

final _openFence = RegExp(r'^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)[^`]*$');

List<_Part> _scan(String text) {
  final parts = <_Part>[];
  final raw = <String>[], body = <String>[];
  String? fence;
  var lang = '';

  void flush(bool code, {bool closed = true}) {
    if (raw.isEmpty) return;
    parts.add(_Part(code, raw.join('\n'), body.join('\n'), lang, closed));
    raw.clear();
    body.clear();
  }

  for (final line in text.split('\n')) {
    if (fence == null) {
      final m = _openFence.firstMatch(line);
      if (m != null) {
        flush(false);
        fence = m.group(1)!;
        lang = m.group(2)!;
        raw.add(line);
        continue;
      }
    } else {
      final t = line.trim();
      if (t.length >= fence.length &&
          t.replaceAll(fence[0], '').isEmpty &&
          RegExp(r'^ {0,3}\S').hasMatch(line)) {
        raw.add(line);
        flush(true);
        fence = null;
        lang = '';
        continue;
      }
      // A closing fence glued to the last code line: "code```".
      if (line.trimRight().endsWith(fence) &&
          !line.contains(fence[0] * (fence.length + 1))) {
        final cut = line.trimRight();
        body.add(cut.substring(0, cut.length - fence.length));
        raw.add(line);
        flush(true);
        fence = null;
        lang = '';
        continue;
      }
    }
    raw.add(line);
    body.add(line);
  }
  flush(fence != null, closed: false);
  return parts;
}

// Spaces, tabs and invisible characters that can fill an "empty" line.
const _gap = r'(?:[^\S\n]|\u200B|\u200C|\u200D|\u2060|\uFEFF)*';
final _leadingBlank = RegExp('^(?:$_gap\n)+');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _mdLink = RegExp(r'\[([^\]\n]+)\]\((https?://[^\s)]+)\)');
final _bareUrl = RegExp(r'https?://[^\s<>"]+');
final _blankRun = RegExp('\n(?:$_gap\n){2,}');

/// The light Markdown that chat models write: **bold**, *actions* (italic,
/// tinted), ***both***, ~~strike~~, `code`, `# headings` and `- bullets`.
/// A marker only counts when it has a partner on the same line, so a half
/// streamed "*smiles" stays as typed until its closing star arrives. Also
/// _italic_, __bold__, `> quotes`, `---` rules and http(s) links, which call
/// [onLink] when tapped; their recognizers are added to [recognizers], for
/// the caller to dispose.
TextSpan formatChat(
  String text, {
  required Color actionColor,
  Color codeFill = const Color(0x22FFFFFF),
  void Function(String url)? onLink,
  List<GestureRecognizer>? recognizers,
  Color? linkColor,
}) {
  final lines = text.split('\n');
  final spans = <InlineSpan>[];
  for (var n = 0; n < lines.length; n++) {
    if (n > 0) spans.add(const TextSpan(text: '\n'));
    var line = lines[n];
    if (_rule.hasMatch(line)) {
      spans.add(const TextSpan(text: '────────────'));
      continue;
    }
    final q = RegExp(r'^\s*>\s?').firstMatch(line);
    if (q != null) {
      spans.add(const TextSpan(text: '▎ '));
      line = line.substring(q.end);
    }
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
        onLink: onLink,
        recognizers: recognizers,
        linkColor: linkColor,
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
  void Function(String url)? onLink,
  List<GestureRecognizer>? recognizers,
  Color? linkColor,
}) {
  final out = <InlineSpan>[];
  final buf = StringBuffer();
  var boldOn = false, italic = false, strike = false;
  // _underscore_ styles, kept apart from the stars so they can't close each
  // other.
  var uBold = false, uItalic = false;

  void link(String label, String url) {
    final tap = onLink == null ? null : TapGestureRecognizer();
    tap?.onTap = () => onLink!(url);
    if (tap != null) recognizers?.add(tap);
    out.add(
      TextSpan(
        text: label,
        recognizer: tap,
        style: TextStyle(
          color: linkColor,
          decoration: TextDecoration.underline,
          decorationColor: linkColor,
        ),
      ),
    );
  }

  void flush() {
    if (buf.isEmpty) return;
    out.add(
      TextSpan(
        text: buf.toString(),
        style: TextStyle(
          fontWeight: bold || boldOn || uBold ? FontWeight.w700 : null,
          fontStyle: italic || uItalic ? FontStyle.italic : null,
          color: italic || uItalic ? actionColor : null,
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
    if (c == '[') {
      final m = _mdLink.matchAsPrefix(line, i);
      if (m != null) {
        flush();
        link(m.group(1)!, m.group(2)!);
        i = m.end;
        continue;
      }
    }
    if (c == 'h' && (i == 0 || !_wordChar.hasMatch(line[i - 1]))) {
      final m = _bareUrl.matchAsPrefix(line, i);
      if (m != null) {
        // Closing punctuation after an address belongs to the sentence.
        var url = m.group(0)!;
        while (RegExp(r'[.,;:!?)\]]$').hasMatch(url)) {
          url = url.substring(0, url.length - 1);
        }
        flush();
        link(url, url);
        i += url.length;
        continue;
      }
    }
    if (c == '_') {
      var run = 1;
      while (i + run < line.length && line[i + run] == '_') {
        run++;
      }
      final before = i > 0 && _wordChar.hasMatch(line[i - 1]);
      final after = i + run < line.length && _wordChar.hasMatch(line[i + run]);
      if (run <= 2 &&
          ((run == 2 && uBold) || (run == 1 && uItalic)) &&
          !spaceAt(i - 1) &&
          !after) {
        flush();
        if (run == 2) {
          uBold = false;
        } else {
          uItalic = false;
        }
        i += run;
        continue;
      }
      if (run <= 2 &&
          !before &&
          !spaceAt(i + run) &&
          RegExp(
            '(?<=\\S)${'_' * run}(?![\\w_])',
          ).hasMatch(line.substring(i + run))) {
        flush();
        if (run == 2) {
          uBold = true;
        } else {
          uItalic = true;
        }
        i += run;
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
