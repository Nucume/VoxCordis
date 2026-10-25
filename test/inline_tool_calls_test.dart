import 'package:companion/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds [chunks] through the parser; returns the visible text and calls.
(String, List<ToolCall>, List<String>) _parse(List<String> chunks) {
  final p = InlineToolCalls({'remember', 'forget'});
  final text = StringBuffer();
  for (final c in chunks) {
    text.write(p.add(c));
  }
  text.write(p.flush());
  return (text.toString(), p.calls, p.stray);
}

void main() {
  test('plain text passes through', () {
    final (text, calls, _) = _parse(['Hello ', 'there <3']);
    expect(text, 'Hello there <3');
    expect(calls, isEmpty);
  });

  test('a Hermes-style call is pulled out of the reply', () {
    final (text, calls, _) = _parse([
      '<tool_call>{"name": "remember", "arguments": ',
      '{"text": "Lena\'s birthday is March 3rd."}}</tool',
      '_call>\nNo worries, I won\'t let you forget!',
    ]);
    expect(text.trim(), "No worries, I won't let you forget!");
    expect(calls.single.name, 'remember');
    expect(
      calls.single.parsedArguments['text'],
      "Lena's birthday is March 3rd.",
    );
  });

  test('tags split one character at a time', () {
    const raw =
        'Ok! <tool_call>{"name":"forget","arguments":{"id":"m1"}}</tool_call>';
    final (text, calls, _) = _parse(raw.split(''));
    expect(text, 'Ok! ');
    expect(calls.single.parsedArguments, {'id': 'm1'});
  });

  test('an unclosed call at the end still counts', () {
    final (text, calls, _) = _parse([
      'Sure.<tool_call>\n{"name": "remember", "arguments": {"text": "x"}}',
    ]);
    expect(text, 'Sure.');
    expect(calls.single.name, 'remember');
  });

  test('a block that is not JSON is hidden and ignored', () {
    final (text, calls, _) = _parse(['Hi<tool_call>oops</tool_call> there']);
    expect(text, 'Hi there');
    expect(calls, isEmpty);
  });

  test('invented tools are dropped, their text kept aside', () {
    final (text, calls, stray) = _parse([
      '<tool_call>{"name": "Mira", "arguments": {"message": "Grow up!"}}</tool_call>',
    ]);
    expect(text, '');
    expect(calls, isEmpty);
    expect(stray, ['Grow up!']);
  });
}
