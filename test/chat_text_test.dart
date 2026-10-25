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
}
