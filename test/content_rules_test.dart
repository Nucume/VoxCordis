import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/content_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cosy = VocesWorld(id: 'c', name: 'Lantern Row', tags: ['Cosy']);
  const doom = VocesWorld(
    id: 'd',
    name: 'Iron Saints',
    tags: ['Brutal', 'War'],
    adult: true,
  );

  test('a cosy world stays cosy, with room for love when mature is on', () {
    final off = ContentRules.forStory(
      world: cosy,
      difficulty: Difficulty.kind,
      mature: false,
    );
    expect(off, contains('nothing sexual is shown explicitly'));
    expect(off, contains('fade out'));
    final on = ContentRules.forStory(
      world: cosy,
      difficulty: Difficulty.kind,
      mature: true,
    );
    expect(on, contains('If love grows'));
    expect(on, isNot(contains('for adults')));
    expect(on, contains('Main tag: Cosy'));
    expect(on, isNot(contains('Flavour')));
  });

  test('an 18+ world shows things in full and follows the human', () {
    final r = ContentRules.forStory(
      world: doom,
      difficulty: Difficulty.grimdark,
      mature: true,
    );
    expect(r, contains('This world is for adults'));
    expect(r, contains('Main tag: Brutal: cruel, merciless violence.'));
    expect(r, contains('Doom-style'));
    expect(r, contains('Flavour: War: battles'));
    expect(r, contains('The human leads'));
    expect(r, contains('Difficulty: Grimdark'));
  });

  test('without Mature content, an 18+ world is played as a normal one', () {
    final r = ContentRules.forStory(
      world: doom,
      difficulty: Difficulty.grimdark,
      mature: false,
    );
    expect(r, isNot(contains('for adults')));
    expect(r, contains('Difficulty: Punishing'));
  });
}
