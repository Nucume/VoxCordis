import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/data/voces/story_log.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/scene_tags.dart';
import 'package:companion/services/voces/story_engine.dart';
import 'package:companion/services/voces/story_export.dart';
import 'package:companion/services/voces/story_notes.dart';

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
    // One turn says and does: words in quotes, actions in asterisks. Only
    // an action goes to the narrator, as Do did.
    expect(
      engine.whoAnswers(
        turn(3, TurnKind.say, '*I open the door.*'),
        before,
        two,
      ),
      isNull,
    );
    expect(
      engine.whoAnswers(
        turn(3, TurnKind.say, '*I lean in.* "Who sent you?"'),
        before,
        two,
      ),
      'mira',
    );
    expect(StoryEngine.onlyAction('*sits* *waits*'), isTrue);
    expect(StoryEngine.onlyAction('Hello there.'), isFalse);
    expect(StoryEngine.onlyAction('*sits* and smiles'), isFalse);
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

  test('a picture turn stays out of what the writers read', () {
    final turns = [
      turn(1, TurnKind.narrator, 'Rain.'),
      turn(2, TurnKind.picture, 'pictures/scene-1.png'),
      turn(3, TurnKind.say, 'Hello.'),
    ];
    expect(engine.transcript(turns), 'Narrator: Rain.\n\nHaru: Hello.');
    expect(TurnKind.picture.aside, isTrue);
    expect(engine.whoContinues([turns[0], turns[1]], two), isNotNull);
  });

  test('Draw the scene: the moment, then tags with their own looks', () {
    final turns = [
      for (var i = 1; i <= 9; i++) turn(i, TurnKind.narrator, 'Line $i.'),
      turn(10, TurnKind.picture, 'pictures/x.png'),
      turn(11, TurnKind.character, 'Down!', by: 'mira', name: 'Mira Vane'),
      turn(12, TurnKind.say, 'Later.'),
    ];
    final brief = SceneTags.brief(engine, turns, turns[10], place: 'The docks');
    expect(brief, contains('- Haru, played by the human'));
    expect(brief, contains('Place: The docks'));
    expect(brief, contains('Mira Vane: Down!'));
    // Six turns up to the one picked, the picture left out.
    expect(brief, isNot(contains('Line 4.')));
    expect(brief, contains('Line 5.'));
    expect(brief, isNot(contains('Later.')));
    expect(brief, isNot(contains('x.png')));

    final cast = [
      mira.copyWith(looksTags: ['red hair', 'eyepatch']),
      tomas.copyWith(looksTags: ['bald']),
      haru.copyWith(looksTags: ['grey coat']),
    ];
    final prompt = SceneTags.prompt(
      '<think>hm</think>**Visible:** Mira, Haru\n'
      'Tags: 1girl, 1boy, ducking, Rain, night, harbor\n',
      cast,
    );
    expect(
      prompt,
      '1girl, 1boy, ducking, rain, night, harbor, red hair, eyepatch, '
      'grey coat',
    );
    expect(SceneTags.prompt('Visible: none\nTags:', cast), '');
    expect(SceneTags.instructions(adult: false), contains('safe for work'));
    expect(SceneTags.instructions(adult: true), contains('sex'));
  });

  test('a story left for a while opens with a recap', () {
    StoryTurn at(int id, DateTime ts) =>
        StoryTurn(id: id, kind: TurnKind.narrator, text: 'Line $id.', ts: ts);
    final then = DateTime(2026, 11, 8, 12);
    final six = [for (var i = 1; i <= 6; i++) at(i, then)];
    // The first open after starting VoxCordis recaps, even soon after.
    expect(
      StoryEngine.wantsRecap(six, then.add(const Duration(minutes: 5))),
      isTrue,
    );
    // After that, only once the story and the last recap are an hour old.
    final shown = then.add(const Duration(minutes: 5));
    expect(
      StoryEngine.wantsRecap(
        six,
        then.add(const Duration(minutes: 30)),
        lastRecap: shown,
      ),
      isFalse,
    );
    expect(
      StoryEngine.wantsRecap(
        six,
        then.add(const Duration(hours: 2)),
        lastRecap: shown,
      ),
      isTrue,
    );
    expect(
      StoryEngine.wantsRecap(
        six.take(5).toList(),
        then.add(const Duration(days: 2)),
      ),
      isFalse,
    );
    final ask = engine.recap(six);
    expect(ask.system, contains('Previously on'));
    expect(ask.system, contains('Haru'));
    expect(ask.user, contains('Line 6.'));
  });

  test(
    'a story exports as a page with its pictures inside, or Markdown',
    () async {
      final dir = Directory.systemTemp.createTempSync('export');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pictures', 'a.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      final turns = [
        turn(1, TurnKind.narrator, 'Place: Docks\nRain <falls>.'),
        turn(2, TurnKind.say, '*waves* "Hi **there**"'),
        turn(3, TurnKind.picture, 'pictures/a.png'),
        turn(4, TurnKind.character, 'Hm.', by: 'mira', name: 'Mira Vane'),
        turn(5, TurnKind.scene, 'Tomas arrives'),
      ];
      final html = await StoryExport.html(
        title: 'Debt & Rain',
        worldName: 'Ember',
        player: 'Haru',
        turns: turns,
        folder: dir.path,
      );
      expect(html, contains('<title>Debt &amp; Rain</title>'));
      expect(html, contains('Rain &lt;falls&gt;.'));
      expect(html, isNot(contains('Place: Docks')));
      expect(html, contains('<em>waves</em>'));
      expect(html, contains('<strong>there</strong>'));
      expect(html, contains('data:image/png;base64,AQID'));
      expect(html, contains('<div class="who">Mira Vane</div>'));
      expect(html, contains('Tomas arrives'));
      final md = StoryExport.markdown(
        title: 'Debt',
        worldName: 'Ember',
        player: 'Haru',
        turns: turns,
        pictures: 'Debt%20pictures',
      );
      expect(md, startsWith('# Debt'));
      expect(md, contains('**Haru:**'));
      expect(md, contains('![](Debt%20pictures/a.png)'));
    },
  );

  test('story notes parse, edit as text and round-trip', () {
    final n = StoryNotes.parse(
      '<think>hm</think>\n**Items:**\n- a brass key\n- 3 coins\n'
      'Quests:\n- Find who sent the letter\n'
      'Feelings:\n- Mira Vane: wary, but warming\n- none\n',
    )!;
    expect(n.items, ['a brass key', '3 coins']);
    expect(n.quests, ['Find who sent the letter']);
    expect(n.feelings, {'Mira Vane': 'wary, but warming'});
    expect(StoryNotes.parse('Nothing to report.'), isNull);
    expect(StoryNotes.parse('Items: rope, lantern')!.items, [
      'rope',
      'lantern',
    ]);

    final back = StoryNotes.fromText(
      items: n.itemsText,
      quests: n.questsText,
      feelings: '${n.feelingsText}\nbroken line',
    );
    expect(back.items, n.items);
    expect(back.feelings, n.feelings);
    expect(StoryNotes.fromJson(n.toJson()).quests, n.quests);
    expect(n.forPrompt('Haru'), contains('Haru carries: a brass key, 3 coins'));
    expect(n.forPrompt('Haru'), contains('Mira Vane towards Haru: wary'));
    expect(
      StoryNotes.brief(const StoryNotes(), 'Haru', 'Haru: Hi.'),
      contains('Items:\n- none'),
    );
  });

  test('fortune rolls on its own only for risky turns in hard stories', () {
    final act = turn(3, TurnKind.act, 'I climb the wall.');
    final say = turn(3, TurnKind.say, 'Hello.');
    final sneak = turn(3, TurnKind.say, '*I pocket the key.*');
    expect(Fortune.rollsOnItsOwn(act, Difficulty.punishing), isTrue);
    expect(Fortune.rollsOnItsOwn(sneak, Difficulty.grimdark), isTrue);
    expect(Fortune.rollsOnItsOwn(say, Difficulty.grimdark), isFalse);
    for (final d in Difficulty.values) {
      if (d == Difficulty.punishing || d == Difficulty.grimdark) continue;
      expect(Fortune.rollsOnItsOwn(act, d), isFalse);
    }
    for (var i = 0; i < 200; i++) {
      expect(Fortune.roll(Random(i)), inInclusiveRange(1, 20));
    }
    expect(Fortune.outcome(1), contains('badly'));
    expect(Fortune.outcome(20), contains('better'));
  });

  test('notes and a roll reach the prompt, and state keeps them', () {
    const notes = StoryNotes(items: ['a brass key']);
    final state = const StoryState(
      present: ['mira'],
    ).copyWith(notes: notes, notesAt: 4, rolls: {3: 2});
    final back = StoryState.fromJson(state.toJson());
    expect(back.notes.items, ['a brass key']);
    expect(back.notesAt, 4);
    expect(back.rolls, {3: 2});

    final turns = [
      turn(1, TurnKind.narrator, 'Rain.'),
      turn(3, TurnKind.act, 'I climb the wall.'),
    ];
    final p = engine.prompt(null, turns, back);
    expect(p.system, contains('# Story notes'));
    expect(p.system, contains('Haru carries: a brass key'));
    expect(p.user, contains('Fortune for what Haru just tried: 2 out of 20'));
    // Once someone has answered, the roll is spent.
    final later = engine.prompt(null, [
      ...turns,
      turn(4, TurnKind.narrator, 'You slip.'),
    ], back);
    expect(later.user, isNot(contains('Fortune')));
  });

  test('scene tags read lists under the label, and bare tag lines', () {
    final p = SceneTags.prompt(
      'Visible:\nMira Vane\n\nTags:\n- 1girl\n- solo\n- rain\n- harbor\n',
      world.cast.values,
    );
    expect(p, startsWith('1girl, solo, rain, harbor'));
    // No labels: only the lines that read as tag lists count.
    expect(
      SceneTags.prompt(
        'Mira looks out over the rainy harbour, thinking.\n'
        '1girl, solo, standing, rain, night',
        world.cast.values,
      ),
      '1girl, solo, standing, rain, night',
    );
    expect(
      SceneTags.prompt(
        'Mira sighs and turns away from the window.',
        world.cast.values,
      ),
      '',
    );
  });
}
