import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/data/voces/story_log.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/story_engine.dart';

StoryTurn turn(
  int id,
  TurnKind kind,
  String text, {
  String? by,
  String name = '',
}) => StoryTurn(
  id: id,
  kind: kind,
  text: text,
  speakerId: by,
  speaker: name,
  ts: DateTime(2026, 11, 6),
);

void main() {
  const mira = VocesCharacter(
    id: 'mira',
    name: 'Mira Vane',
    line: 'Smuggler captain',
    sections: [SheetSection('Personality', 'Dry, quick, loyal.')],
  );
  const tomas = VocesCharacter(id: 'tomas', name: 'Tomas', line: 'Dockhand');
  const oren = VocesCharacter(id: 'oren', name: 'Oren', line: 'Harbourmaster');
  const haru = VocesCharacter(
    id: 'haru',
    name: 'Haru',
    line: 'A stranger in town',
    sections: [SheetSection('Looks', 'Grey coat.')],
  );
  final story = StorySave(
    id: 's',
    title: 'Lantern Debt',
    worldId: 'ember',
    worldName: 'Ember Coast',
    playerId: 'haru',
    playerName: 'Haru',
    difficulty: Difficulty.punishing,
    created: DateTime(2026, 11, 6),
    lastPlayed: DateTime(2026, 11, 6),
  );
  final world = StoryWorld(
    story: story,
    world: const VocesWorld(
      id: 'ember',
      name: 'Ember Coast',
      setting: 'A rainy harbour.',
      tags: ['Fantasy', 'Mystery'],
      castIds: ['mira', 'tomas', 'oren'],
    ),
    cast: const {'mira': mira, 'tomas': tomas, 'oren': oren, 'haru': haru},
    lorebooks: const [
      Lorebook(
        id: 'lore',
        name: 'Lore',
        entries: [
          LoreEntry(
            title: 'The lighthouse',
            keys: ['lighthouse'],
            text: 'Never dark.',
          ),
          LoreEntry(title: 'The Crown', keys: ['crown'], text: 'Taxes all.'),
        ],
      ),
    ],
    folder: '/nowhere',
  );
  final engine = StoryEngine(world, mature: false, random: Random(1));
  const two = StoryState(present: ['mira', 'tomas']);

  test('starting cast: the chosen, else the first three, never the player', () {
    expect(engine.startingCast(), ['mira', 'tomas', 'oren']);
    expect(engine.startingCast(['tomas', 'haru', 'nobody']), ['tomas']);
  });

  test('who answers the human', () {
    final said = turn(5, TurnKind.say, 'Tomas, fetch the rope.');
    expect(engine.whoAnswers(said, const [], two), 'tomas');
    // First names count.
    final hi = turn(5, TurnKind.say, 'Thanks, mira.');
    expect(engine.whoAnswers(hi, const [], two), 'mira');
    // Nobody named: whoever spoke last.
    final before = [
      turn(1, TurnKind.narrator, 'Rain.'),
      turn(2, TurnKind.character, 'Hm.', by: 'mira', name: 'Mira Vane'),
    ];
    final plain = turn(3, TurnKind.say, 'And then?');
    expect(engine.whoAnswers(plain, before, two), 'mira');
    // After the narrator, with two here: the narrator.
    expect(
      engine.whoAnswers(plain, [turn(1, TurnKind.narrator, 'Rain.')], two),
      isNull,
    );
    // Only one here: them.
    expect(
      engine.whoAnswers(plain, const [], const StoryState(present: ['oren'])),
      'oren',
    );
    // Doing and asking go to the narrator unless someone is named.
    expect(
      engine.whoAnswers(turn(3, TurnKind.act, 'I open the door.'), before, two),
      isNull,
    );
    expect(
      engine.whoAnswers(
        turn(3, TurnKind.act, 'I hand Tomas a coin.'),
        before,
        two,
      ),
      'tomas',
    );
    expect(
      engine.whoAnswers(turn(3, TurnKind.ask, 'Tomas trips.'), before, two),
      isNull,
    );
  });

  test('continue: a quiet character after the narrator, else the narrator', () {
    final turns = [
      turn(1, TurnKind.character, 'Hm.', by: 'mira', name: 'Mira Vane'),
      turn(2, TurnKind.narrator, 'The rain thickens.'),
    ];
    expect(engine.whoContinues(turns, two), 'tomas');
    expect(engine.whoContinues(turns.take(1).toList(), two), isNull);
    expect(
      engine.whoContinues([turn(1, TurnKind.narrator, 'Tomas waves.')], two),
      'tomas',
    );
  });

  test('chains pass to whoever is named, and stop at the player', () {
    expect(engine.chainsTo('Tomas, the ropes!', 'mira', two), 'tomas');
    expect(engine.chainsTo('Right, Tomas.', 'tomas', two), isNull);
    expect(engine.chainsTo('Tomas, ask Haru.', 'mira', two), isNull);
    expect(
      engine.chainsTo('Tomas knows. What do you think?', 'mira', two),
      isNull,
    );
  });

  test('comings and goings follow liveliness, and pins stay', () {
    var arrived = 0;
    var left = 0;
    final e = StoryEngine(world, mature: false, random: Random(7));
    const state = StoryState(
      present: ['mira', 'tomas'],
      pinned: {'mira'},
      liveliness: Liveliness.busy,
    );
    for (var i = 0; i < 2000; i++) {
      final c = e.rollChange(state);
      if (c == null) continue;
      if (c.arrives) {
        expect(c.who.id, 'oren');
        arrived++;
      } else {
        expect(c.who.id, 'tomas');
        left++;
      }
    }
    expect(arrived, inInclusiveRange(400, 600));
    expect(left, inInclusiveRange(180, 320));
  });

  test('the narrator prompt', () {
    final turns = [
      turn(1, TurnKind.narrator, 'The lighthouse glows.'),
      turn(2, TurnKind.say, 'Who keeps it lit?'),
      turn(3, TurnKind.act, 'I knock.'),
      turn(4, TurnKind.scene, 'Oren arrives', by: 'oren'),
    ];
    final change = CastChange(oren, arrives: true);
    final prompt = engine.prompt(
      null,
      turns,
      two.copyWith(place: 'The quay'),
      change: change,
    );
    expect(prompt.system, contains('narrator of a roleplay story'));
    expect(
      prompt.system,
      contains('Never speak, act, think or decide for Haru'),
    );
    expect(prompt.system, contains('Grey coat.')); // the player's sheet
    expect(prompt.system, contains('Where: The quay'));
    expect(prompt.system, contains('- Mira Vane - Smuggler captain'));
    expect(prompt.system, contains('The lighthouse: Never dark.'));
    expect(prompt.system, isNot(contains('Taxes all.')));
    expect(prompt.system, contains('Difficulty: Punishing'));
    expect(prompt.user, contains('Narrator: The lighthouse glows.'));
    expect(prompt.user, contains('Haru: Who keeps it lit?'));
    expect(prompt.user, contains('Haru (does): I knock.'));
    expect(prompt.user, contains('[Oren arrives]'));
    expect(prompt.user, contains('Oren arrives now'));
    expect(prompt.user, endsWith("Now write Narrator's next reply."));
    expect(prompt.stop, ['\nHaru:', '\nMira Vane:', '\nTomas:']);
  });

  test('a character prompt has their sheet and only lines for others', () {
    final prompt = engine.prompt('mira', const [], two);
    expect(prompt.system, startsWith('You are Mira Vane'));
    expect(prompt.system, contains('Dry, quick, loyal.'));
    expect(prompt.system, isNot(contains('Grey coat.')));
    expect(prompt.system, contains('Haru - A stranger in town'));
    expect(prompt.system, contains('- Tomas - Dockhand'));
    expect(prompt.user, endsWith("Now write Mira Vane's next reply."));
    expect(prompt.stop, ['\nHaru:', '\nNarrator:', '\nTomas:']);
  });

  test('the transcript keeps the newest turns', () {
    final long = [
      for (var i = 0; i < 100; i++)
        turn(i, TurnKind.narrator, 'Turn $i ${'x' * 300}'),
    ];
    final t = engine.transcript(long);
    expect(t.length, lessThanOrEqualTo(StoryEngine.window + 400));
    expect(t, contains('Turn 99 '));
    expect(t, isNot(contains('Turn 0 ')));
  });

  test('clean drops names in front and other speakers after', () {
    expect(engine.clean('Mira Vane: Fine.\nHaru: Thanks!', 'mira'), 'Fine.');
    expect(engine.clean('Rain falls.\n\nTomas: Oi!', null), 'Rain falls.');
  });

  test('a narrator reply may start with a new place', () {
    var s = StoryEngine.splitPlace('Place: The Gull tavern\nSmoke hangs.');
    expect(s.place, 'The Gull tavern');
    expect(s.text, 'Smoke hangs.');
    s = StoryEngine.splitPlace('**Place:** Old pier\n\nWaves.');
    expect(s.place, 'Old pier');
    expect(s.text, 'Waves.');
    s = StoryEngine.splitPlace('Waves. The place is quiet.');
    expect(s.place, isNull);
  });

  test('state round trip', () {
    const s = StoryState(
      present: ['mira'],
      pinned: {'mira'},
      place: 'Quay',
      liveliness: Liveliness.calm,
      chain: 3,
    );
    final back = StoryState.fromJson(s.toJson());
    expect(back.present, ['mira']);
    expect(back.pinned, {'mira'});
    expect(back.place, 'Quay');
    expect(back.liveliness, Liveliness.calm);
    expect(back.chain, 3);
    expect(StoryState.fromJson(const {'chain': 9}).chain, StoryState.maxChain);
  });

  test('the story log keeps turns and state', () async {
    final dir = Directory.systemTemp.createTempSync('story_log');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'stories', 's.db');
    await Directory(p.dirname(path)).create(recursive: true);
    var log = await StoryLog.open(path, key: 'secret');
    final a = await log.add(TurnKind.narrator, 'Rain.');
    final b = await log.add(
      TurnKind.character,
      'Hm.',
      speakerId: 'mira',
      speaker: 'Mira Vane',
    );
    await log.add(TurnKind.say, 'Hello.');
    await log.edit(b.id, 'Hmph.');
    await log.setState('story', {'place': 'Quay'});
    await log.close();

    log = await StoryLog.open(path, key: 'secret');
    var turns = await log.turns();
    expect(turns.map((t) => t.text), ['Rain.', 'Hmph.', 'Hello.']);
    expect(turns[1].kind, TurnKind.character);
    expect(turns[1].speaker, 'Mira Vane');
    expect((await log.state())['story'], {'place': 'Quay'});
    await log.dropFrom(b.id);
    turns = await log.turns();
    expect(turns.single.id, a.id);
    await log.close();
  });

  test('a narrator-led world gives the narrator everyone else', () {
    final led = StoryWorld(
      story: story,
      world: world.world.copyWith(narratorLed: true),
      cast: world.cast,
      lorebooks: world.lorebooks,
      folder: world.folder,
    );
    final e = StoryEngine(led, mature: false);
    expect(
      e.prompt(null, const [], two).system,
      contains('run this whole game'),
    );
    expect(
      engine.prompt(null, const [], two).system,
      isNot(contains('run this whole game')),
    );
  });

  test('lore found by meaning joins the key-word lore', () {
    final crown = world.lorebooks.single.entries[1];
    final prompt = engine.prompt(
      null,
      [turn(1, TurnKind.say, 'Who rules here?')],
      two,
      byMeaning: [crown],
    );
    expect(prompt.system, contains('The Crown: Taxes all.'));
    expect(engine.loreEntries.length, 2);
    expect(
      engine.recentText([
        turn(1, TurnKind.say, 'a'),
        turn(2, TurnKind.scene, 'x arrives'),
        turn(3, TurnKind.narrator, 'b'),
      ]),
      'a\nb',
    );
  });
}
