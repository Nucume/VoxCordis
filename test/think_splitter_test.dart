import 'package:companion/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds [chunks] through a splitter and joins what comes out by kind.
(String reasoning, String text) _split(List<String> chunks) {
  final s = ThinkSplitter();
  final events = [for (final c in chunks) ...s.add(c), ...s.flush()];
  final r = StringBuffer(), t = StringBuffer();
  for (final e in events) {
    switch (e) {
      case ReasoningDelta(:final text):
        r.write(text);
      case TextDelta(:final text):
        t.write(text);
      default:
    }
  }
  return (r.toString(), t.toString());
}

void main() {
  test('plain text passes through', () {
    expect(_split(['Hello ', 'there']), ('', 'Hello there'));
  });

  test('an inline think block becomes reasoning', () {
    expect(_split(['<think>Hmm, tea.</think>\n\nGenmaicha!']), (
      'Hmm, tea.',
      'Genmaicha!',
    ));
  });

  test('tags split across chunks', () {
    expect(_split(['<th', 'ink>Let me ', 'see.</th', 'ink>Hi', ' again']), (
      'Let me see.',
      'Hi again',
    ));
  });

  test('a think tag later in the reply is left as text', () {
    expect(_split(['I <think> so']), ('', 'I <think> so'));
  });

  test('an unclosed think block is all reasoning', () {
    expect(_split(['<think>still going']), ('still going', ''));
  });
}
