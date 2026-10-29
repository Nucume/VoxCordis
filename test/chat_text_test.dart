import 'package:companion/features/chat/chat_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flattens to "text|b|i|s" pieces so the expectations stay readable.
List<String> pieces(String s) {
  final out = <String>[];
  formatChat(s, actionColor: Colors.pink).visitChildren((span) {
    final t = span as TextSpan;
    if (t.text == null) return true;
    final st = t.style;
    out.add(
      [
        t.text,
        if (st?.fontWeight == FontWeight.w700) 'b',
        if (st?.fontStyle == FontStyle.italic) 'i',
        if (st?.decoration == TextDecoration.lineThrough) 's',
        if (st?.fontFamily == 'monospace') 'code',
      ].join('|'),
    );
    return true;
  });
  return out;
}

void main() {
  test('bold and actions', () {
    expect(pieces('1. **Game Night**: fun'), ['1. ', 'Game Night|b', ': fun']);
    expect(pieces('*smiles softly* Hi!'), ['smiles softly|i', ' Hi!']);
    expect(pieces('***wow***'), ['wow|b|i']);
    expect(pieces('*she **really** smiles*'), [
      'she |i',
      'really|b|i',
      ' smiles|i',
    ]);
  });

  test('unfinished or loose stars stay as typed', () {
    expect(pieces('*smiles'), ['*smiles']);
    expect(pieces('2 * 3 = 6'), ['2 * 3 = 6']);
    expect(pieces(r'\*not\*'), ['*not*']);
  });

  test('code, strike, headings and bullets', () {
    expect(pieces('use `x*y*z` now'), ['use ', 'x*y*z|code', ' now']);
    expect(pieces('~~old~~ new'), ['old|s', ' new']);
    expect(pieces('## Ideas'), ['Ideas|b']);
    expect(pieces('- one\n* two'), ['•  ', 'one', '\n', '•  ', 'two']);
  });

  test('blank lines are tidied', () {
    expect(tidyBlankLines('\n\n \n\u200B\n*sighs*'), '*sighs*');
    expect(tidyBlankLines('Hi.\n\n\n\n  \n\n\nBye.'), 'Hi.\n\nBye.');
    expect(tidyBlankLines('Hi.\n\nBye.\n  - one'), 'Hi.\n\nBye.\n  - one');
    expect(tidyBlankLines('  indented'), '  indented');
  });

  test('fenced code blocks', () {
    final b = chatBlocks('Here:\n```\n*a*\n\n\n\nb\n```\nBye');
    expect(b.map((e) => e.code), [false, true, false]);
    expect(b[1].text, '*a*\n\n\n\nb');
    expect(b[2].text, 'Bye');
    final py = chatBlocks('```python\nx = 1\n```');
    expect(py.single.lang, 'python');
    expect(py.single.text, 'x = 1');
    // Still streaming: the open fence already shows as code.
    expect(chatBlocks('Hi\n```\npart').last.code, true);
    expect(chatBlocks('a ``` b').single.code, false);
    expect(chatBlocks('```\ncode```\nafter').first.text, 'code');
  });

  test('blank lines inside code stay', () {
    const s = 'A\n\n\n\nB\n```\nx\n\n\n\ny\n```\n\n\n\nC';
    expect(tidyBlankLines(s), 'A\n\nB\n```\nx\n\n\n\ny\n```\n\nC');
  });

  test('quotes and rules', () {
    expect(pieces('> hi'), ['▎ ', 'hi']);
    expect(pieces('---'), ['────────────']);
  });

  test('underscores and links', () {
    expect(pieces('_hi_ there'), ['hi|i', ' there']);
    expect(pieces('__big__'), ['big|b']);
    expect(pieces('snake_case_name'), ['snake_case_name']);
    expect(pieces('a [site](https://x.org/a) b'), ['a ', 'site', ' b']);
    expect(pieces('see https://x.org/a.'), ['see ', 'https://x.org/a', '.']);
    expect(pieces('[x](javascript:alert(1))'), ['[x](javascript:alert(1))']);
  });

  test('tables', () {
    final b = chatBlocks('Look:\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 |\nEnd');
    expect(b.map((e) => e.rows != null), [false, true, false]);
    expect(b[1].rows, [
      ['a', 'b'],
      ['1', '2'],
      ['3', ''],
    ]);
    expect(chatBlocks('a | b\nplain').length, 1);
  });

  test('choices become buttons once closed', () {
    final b = chatBlocks('Tea?\n```choices\n- Yes\n2. No\n\nLater\n```');
    expect(b.last.choices, ['Yes', 'No', 'Later']);
    expect(chatBlocks('Tea?\n```choices\nYes').map((e) => e.text), ['Tea?']);
  });
}
