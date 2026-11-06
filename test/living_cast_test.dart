import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:companion/data/voces/story_log.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/living_cast.dart';
import 'package:companion/services/voces/story_engine.dart';

StoryTurn turn(int id, TurnKind kind, String text) =>
    StoryTurn(id: id, kind: kind, text: text, ts: DateTime(2026, 11, 6));

void main() {
  test('name candidates leave out known names and common words', () {
    final c = LivingCast.candidates(
      'The door opens. Old Brannoc the ferryman nods at Mira Vane. '
      'Behind him, Sela waits by the Lantern.',
      {'Mira Vane', 'Haru'},
    );
    expect(c, containsAll(['Old Brannoc', 'Sela', 'Lantern']));
    expect(c, isNot(contains('The')));
    expect(c, isNot(contains('Behind')));
    expect(c.where((w) => w.contains('Mira')), isEmpty);
  });

  test('found people are read from the reply', () {
    final found = LivingCast.parseFound(
      '<think>hm</think>\n- **Brannoc** - the old ferryman\n'
      'Sela: a girl selling eels\nMira Vane - captain\nnone',
      {'mira vane'},
    );
    expect(found.map((e) => e.name), ['Brannoc', 'Sela']);
    expect(found.first.line, 'the old ferryman');
    expect(LivingCast.parseFound('none', const {}), isEmpty);
  });

  test('extras are counted, and ripe when seen often or talked to', () {
    var extras = [const Extra('Brannoc', 'ferryman')];
    extras = LivingCast.count(
      extras,
      turn(1, TurnKind.narrator, 'Brannoc rows.'),
    );
    extras = LivingCast.count(
      extras,
      turn(2, TurnKind.say, 'Thanks, brannoc!'),
    );
    expect(extras.single.seen, 3);
    expect(extras.single.talked, 1);
    expect(LivingCast.ripe(extras.single), isFalse);
    extras = LivingCast.count(extras, turn(3, TurnKind.say, 'Brannoc, wait.'));
    expect(LivingCast.ripe(extras.single), isTrue);
    // Scene dividers don't count.
    final same = LivingCast.count(
      extras,
      turn(4, TurnKind.scene, 'Brannoc arrives'),
    );
    expect(same.single.seen, extras.single.seen);
  });

  test('merge keeps the list short, the most seen first to stay', () {
    final many = [
      for (var i = 0; i < LivingCast.maxExtras; i++)
        Extra('P$i', '', seen: i + 2),
    ];
    final merged = LivingCast.merge(many, [
      const Extra('New', ''),
      const Extra('P3', ''),
    ]);
    expect(merged.length, LivingCast.maxExtras);
    expect(merged.map((e) => e.name), isNot(contains('P0')));
    expect(merged.where((e) => e.name == 'P3').length, 1);
  });

  test('excerpts are the turns that name them', () {
    final ex = LivingCast.excerpts('Sela', [
      turn(1, TurnKind.narrator, 'Rain.'),
      turn(2, TurnKind.narrator, 'Sela sells eels.'),
      turn(3, TurnKind.say, 'Two eels, Sela.'),
    ], playerName: 'Haru');
    expect(ex, 'Narrator: Sela sells eels.\n\nHaru: Two eels, Sela.');
  });

  test('extras round-trip in the story state and reach the narrator', () {
    const state = StoryState(extras: [Extra('Sela', 'eel seller', seen: 2)]);
    final back = StoryState.fromJson(state.toJson());
    expect(back.extras.single.name, 'Sela');
    expect(back.extras.single.seen, 2);
    final story = StorySave(
      id: 's',
      title: 'T',
      worldId: 'w',
      worldName: 'W',
      playerId: 'haru',
      playerName: 'Haru',
      created: DateTime(2026),
      lastPlayed: DateTime(2026),
    );
    final engine = StoryEngine(
      StoryWorld(
        story: story,
        world: const VocesWorld(id: 'w', name: 'W'),
        cast: {'haru': const VocesCharacter(id: 'haru', name: 'Haru')},
        lorebooks: const [],
        folder: '/nowhere',
      ),
      mature: false,
    );
    expect(
      engine.prompt(null, const [], back).system,
      contains('- Sela - eel seller'),
    );
  });

  test('story characters are saved in the story and copied out', () async {
    final dir = Directory.systemTemp.createTempSync('living_cast');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lib = VocesLibrary.inside(dir.path);
    final haru = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Haru'),
    );
    final world = await lib.saveWorld(const VocesWorld(id: '', name: 'Ember'));
    final story = await lib.startStory(
      world: world,
      player: haru,
      title: 'Run',
    );
    final sela = await lib.saveStoryCharacter(
      story,
      const VocesCharacter(id: '', name: 'Sela', line: 'eel seller'),
    );
    expect(
      (await lib.storyWorld(story)).cast.keys,
      containsAll(['haru', 'sela']),
    );
    expect(await lib.characters(), hasLength(1)); // not in Characters yet
    final copy = await lib.copyFromStory(story, sela, name: 'Sela 2');
    expect(copy.name, 'Sela 2');
    expect((await lib.characters()).map((c) => c.name), contains('Sela 2'));
  });
}
