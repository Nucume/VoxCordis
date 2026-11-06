import 'package:flutter_test/flutter_test.dart';

import 'package:companion/data/settings.dart';
import 'package:companion/services/voces/describer.dart';

void main() {
  test('a world comes back field by field', () {
    final w = WorldDescriber.parse('''
<think>hmm</think>
**Name:** Bellwater
Line: A drowned city where the bells ring at low tide.
Tags: Mystery, Supernatural, Gore
Setting:
The tide goes out once a year.

Nobody knows who rings the bells.
Opening title: Low tide
Opening:
The water draws back from the square, and the first bell sounds somewhere
beneath your feet, slow and green with rust, as the crowd goes quiet.
''')!;
    expect(w.name, 'Bellwater');
    expect(w.line, startsWith('A drowned city'));
    expect(w.tags, ['Mystery', 'Supernatural']); // no 18+ tags here
    expect(w.setting, contains('Nobody knows'));
    expect(w.opening!.title, 'Low tide');
    expect(w.opening!.text, startsWith('The water draws back'));
  });

  test('nothing usable gives null', () {
    expect(WorldDescriber.parse('Sorry, I can\'t help.'), isNull);
    expect(CharacterDescriber.parse(''), isNull);
  });

  test('a character comes back with their sheet', () {
    final c = CharacterDescriber.parse('''
Name: Oren Vale
Pronouns: he/him
Line: Retired lighthouse keeper.
Traits: patient, wry, haunted
Who they are:
Kept the light for forty years.
Personality:
Slow to anger.
Looks:
Grey beard, oilskin coat.
How they talk:
Short sentences. "Fog's thick tonight."
''')!;
    expect(c.name, 'Oren Vale');
    expect(c.pronouns, 'he/him');
    expect(c.traits, ['patient', 'wry', 'haunted']);
    expect(c.sections.map((s) => s.heading), CharacterDescriber.parts);
    expect(c.sections.last.text, contains('Fog'));
  });

  test('model size from its name', () {
    AppSettings with_(String? path, String model, LlmMode mode) =>
        AppSettings(modelPath: path, llmModel: model, llmMode: mode);
    expect(
      modelBillions(
        with_('/m/Rocinante-12B-v1.1-Q4_K_M.gguf', '', LlmMode.builtIn),
      ),
      12,
    );
    expect(modelBillions(with_(null, 'qwen3:8b', LlmMode.external)), 8);
    expect(modelBillions(with_(null, 'gemma-3n-E4B-it', LlmMode.external)), 4);
    expect(
      modelBillions(with_(null, 'anthropic/claude', LlmMode.external)),
      isNull,
    );
  });
}
