import 'dart:convert';
import 'dart:io';

import 'package:companion/data/voces/lore_match.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/describer.dart';
import 'package:companion/features/voces/voces_picture.dart';
import 'package:companion/services/import/imported_character.dart';
import 'package:companion/services/import/voces_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late VocesLibrary lib;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voces');
    lib = VocesLibrary.inside(tmp.path);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('ids come from names and never collide', () async {
    expect(VocesLibrary.slug('Ember Coast'), 'ember-coast');
    expect(VocesLibrary.slug("Mira's Ship!"), 'miras-ship');
    expect(VocesLibrary.slug('ハル'), 'ハル');
    expect(VocesLibrary.slug('  '), 'untitled');
    final a = await lib.saveWorld(
      const VocesWorld(id: '', name: 'Ember Coast'),
    );
    final b = await lib.saveWorld(
      const VocesWorld(id: '', name: 'Ember Coast'),
    );
    expect(a.id, 'ember-coast');
    expect(b.id, 'ember-coast-2');
    expect((await lib.worlds()).map((w) => w.id), [
      'ember-coast',
      'ember-coast-2',
    ]);
  });

  test('everything round-trips through its file', () async {
    final mira = await lib.saveCharacter(
      VocesCharacter(
        id: '',
        name: 'Mira',
        line: 'Smuggler captain',
        tags: const ['bold'],
        sections: const [SheetSection('Who they are', 'Runs the coast.')],
        created: DateTime(2026, 11, 5),
      ),
    );
    final book = await lib.saveLorebook(
      const Lorebook(
        id: '',
        name: 'Ember lore',
        entries: [
          LoreEntry(title: 'Light', keys: ['lighthouse'], text: 'Never dark.'),
        ],
      ),
    );
    await lib.saveWorld(
      VocesWorld(
        id: '',
        name: 'Ember Coast',
        setting: 'Rain.',
        castIds: [mira.id],
        lorebookIds: [book.id],
        openings: const [Opening('Back room', 'Rain hammers the shutters.')],
      ),
    );
    final world = (await lib.worlds()).single;
    expect(world.castIds, ['mira']);
    expect(world.openings.single.text, 'Rain hammers the shutters.');
    final c = (await lib.characters()).single;
    expect(c.sections.single.text, 'Runs the coast.');
    expect(c.created, DateTime(2026, 11, 5));
    expect((await lib.lorebooks()).single.entries.single.keys, ['lighthouse']);
  });

  test('a story can take what changed in its world, part by part', () async {
    final mira = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Mira'),
    );
    final haru = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Haru'),
    );
    final lore = await lib.saveLorebook(const Lorebook(id: '', name: 'Lore'));
    final old = await lib.saveLorebook(const Lorebook(id: '', name: 'Old'));
    var world = await lib.saveWorld(
      VocesWorld(
        id: '',
        name: 'Ember',
        setting: 'Old',
        castIds: [mira.id],
        lorebookIds: [lore.id, old.id],
      ),
    );
    var story = await lib.startStory(world: world, player: haru, title: 'Debt');
    expect((await lib.worldUpdate(story))!.isEmpty, isTrue);

    // Edits after the story began.
    final tomas = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Tomas'),
    );
    final extra = await lib.saveLorebook(const Lorebook(id: '', name: 'Extra'));
    await lib.saveCharacter(mira.copyWith(name: 'Mira Vey'));
    await lib.saveCharacter(haru.copyWith(name: 'Haru K'));
    await lib.saveLorebook(
      Lorebook(id: lore.id, name: 'Lore', source: 'edited'),
    );
    world = await lib.saveWorld(
      world.copyWith(
        name: 'Ember Coast',
        setting: 'New',
        castIds: [mira.id, tomas.id, haru.id],
        lorebookIds: [lore.id, extra.id],
      ),
    );

    final u = (await lib.worldUpdate(story))!;
    expect(u.world?.setting, 'New');
    expect(
      {for (final b in u.lorebooks) b.book.id: b.change},
      {
        'lore': WorldChange.changed,
        'extra': WorldChange.added,
        'old': WorldChange.removed,
      },
    );
    // The player keeps their own sheet.
    expect(
      {for (final c in u.cast) c.character.id: c.change},
      {'mira': WorldChange.changed, 'tomas': WorldChange.added},
    );

    // Take the world, two lorebooks and the newcomer; Mira stays as she is.
    story = await lib.applyWorldUpdate(
      story,
      u,
      world: true,
      lorebooks: {'extra', 'old'},
      cast: {'tomas'},
    );
    expect(story.worldName, 'Ember Coast');
    final sw = await lib.storyWorld(story);
    expect(sw.world.setting, 'New');
    expect(sw.lorebooks.map((b) => b.id).toSet(), {'lore', 'extra'});
    expect(sw.lorebooks.firstWhere((b) => b.id == 'lore').source, '');
    expect(sw.cast['mira']!.name, 'Mira');
    expect(sw.cast['tomas']!.name, 'Tomas');
    expect(sw.cast['haru']!.name, 'Haru');
    expect((await lib.stories()).single.worldName, 'Ember Coast');

    final left = (await lib.worldUpdate(story))!;
    expect(left.world, isNull);
    expect(left.lorebooks.single.book.id, 'lore');
    expect(left.cast.single.character.id, 'mira');

    await lib.deleteWorld(world.id);
    expect(await lib.worldUpdate(story), isNull);
  });

  test('a branch copies the story folder under a new title', () async {
    final haru = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Haru'),
    );
    final world = await lib.saveWorld(
      const VocesWorld(id: '', name: 'Ember', setting: 'Rain'),
    );
    final story = await lib.startStory(
      world: world,
      player: haru,
      title: 'Debt',
    );
    final pic = File(p.join(lib.storyFolder(story.id), 'pictures', 'a.png'))
      ..createSync(recursive: true);
    final copy = await lib.branchStory(story, title: 'Debt (branch)');
    expect(copy.id, isNot(story.id));
    expect(copy.title, 'Debt (branch)');
    expect(copy.playerId, story.playerId);
    expect(
      File(
        p.join(lib.storyFolder(copy.id), 'pictures', p.basename(pic.path)),
      ).existsSync(),
      isTrue,
    );
    expect((await lib.storyWorld(copy)).world.setting, 'Rain');
    expect((await lib.stories()).map((s) => s.title).toSet(), {
      'Debt',
      'Debt (branch)',
    });
  });

  test('a story copies the world, so later edits leave it alone', () async {
    final mira = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Mira'),
    );
    final haru = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Haru'),
    );
    await lib.saveCharacter(const VocesCharacter(id: '', name: 'Stranger'));
    final book = await lib.saveLorebook(const Lorebook(id: '', name: 'Lore'));
    var world = await lib.saveWorld(
      VocesWorld(
        id: '',
        name: 'Ember',
        setting: 'Old',
        castIds: [mira.id],
        lorebookIds: [book.id],
      ),
    );
    final story = await lib.startStory(
      world: world,
      player: haru,
      title: 'The Lantern Debt',
      difficulty: Difficulty.punishing,
      now: DateTime(2026, 11, 5, 20),
    );
    world = await lib.saveWorld(world.copyWith(setting: 'New'));

    final folder = lib.storyFolder(story.id);
    final copy = jsonDecode(
      await File(p.join(folder, 'world.json')).readAsString(),
    );
    expect(copy['setting'], 'Old');
    expect(
      await File(p.join(folder, 'cast', 'mira', 'character.json')).exists(),
      isTrue,
    );
    expect(
      await File(p.join(folder, 'cast', 'haru', 'character.json')).exists(),
      isTrue,
    );
    expect(
      await Directory(p.join(folder, 'cast', 'stranger')).exists(),
      isFalse,
    );
    expect(
      await File(p.join(folder, 'lorebooks', 'lore.json')).exists(),
      isTrue,
    );
    final saved = (await lib.stories()).single;
    expect(saved.playerName, 'Haru');

    // The story plays from its own copy.
    final sw = await lib.storyWorld(saved);
    expect(sw.world.setting, 'Old');
    expect(sw.player?.name, 'Haru');
    expect(sw.cast.keys.toSet(), {'mira', 'haru'});
    expect(sw.lorebooks.single.id, 'lore');
    expect(saved.difficulty, Difficulty.punishing);
    expect(
      StorySave.fromJson({'lean': 'ruthless'}).difficulty,
      Difficulty.punishing,
    );
  });

  test('stories list the one played last first', () async {
    StorySave s(String id, int day) => StorySave(
      id: id,
      title: id,
      worldId: 'w',
      worldName: 'W',
      playerId: 'p',
      playerName: 'P',
      created: DateTime(2026, 11, 1),
      lastPlayed: DateTime(2026, 11, day),
    );
    await lib.saveStory(s('old', 1));
    await lib.saveStory(s('new', 4));
    expect((await lib.stories()).map((x) => x.id), ['new', 'old']);
  });

  test('a broken file is skipped, not fatal', () async {
    await lib.saveCharacter(const VocesCharacter(id: '', name: 'Fine'));
    final bad = File(
      p.join(lib.root, 'characters', 'broken', 'character.json'),
    );
    await bad.parent.create(recursive: true);
    await bad.writeAsString('{nope');
    expect((await lib.characters()).map((c) => c.name), ['Fine']);
  });

  test('deleting never reaches outside the library', () async {
    final outside = Directory(p.join(tmp.path, 'keep'))..createSync();
    await lib.deleteWorld('../../keep');
    expect(outside.existsSync(), isTrue);
  });

  group('lore', () {
    const light = LoreEntry(
      title: 'Light',
      keys: ['lighthouse', 'Kael'],
      text: 'x',
    );
    const art = LoreEntry(title: 'Art', keys: ['art'], text: 'x');
    const tone = LoreEntry(title: 'Tone', text: 'x', always: true);
    const off = LoreEntry(
      title: 'Off',
      keys: ['rain'],
      text: 'x',
      enabled: false,
    );

    test('key words match whole words in any case', () {
      expect(LoreMatch.match('Is the LIGHTHOUSE lit?', [light, art]), [light]);
      expect(LoreMatch.match('a party at dawn', [art]), isEmpty);
      expect(LoreMatch.match("Kael's pipe", [light]), [light]);
    });

    test('always-on entries come in, switched-off ones never', () {
      expect(LoreMatch.match('rain again', [tone, off]), [tone]);
    });

    test('search looks through worlds, characters and lore', () {
      final hits = searchVoces(
        'light',
        worlds: const [
          VocesWorld(id: 'w', name: 'Ember', setting: 'A lighthouse town'),
        ],
        characters: const [
          VocesCharacter(id: 'k', name: 'Kael', line: 'Keeps the light'),
        ],
        lorebooks: const [
          Lorebook(id: 'b', name: 'Lore', entries: [light]),
        ],
      );
      expect(hits, hasLength(3));
      expect(hits[0], isA<WorldHit>());
      expect(hits[1], isA<CharacterHit>());
      expect(hits[2], isA<LoreHit>());
      expect(
        searchVoces(
          'kael pipe',
          worlds: const [],
          characters: const [],
          lorebooks: const [],
        ),
        isEmpty,
      );
    });
  });

  group('import', () {
    test('a V2 card brings its character and its lorebook', () async {
      final f = File(p.join(tmp.path, 'mira.json'))
        ..writeAsStringSync(
          jsonEncode({
            'spec': 'chara_card_v2',
            'data': {
              'name': 'Mira',
              'description': 'A smuggler captain. She owes no one.',
              'personality': 'bold, witty',
              'scenario': '{{user}} owes {{char}} money.',
              'first_mes': 'Well, look who washed in.',
              'system_prompt': 'You are an AI.',
              'character_book': {
                'entries': [
                  {
                    'keys': ['lighthouse'],
                    'content': 'The <b>light</b> never goes dark.',
                    'comment': 'The light',
                  },
                  {'keys': [], 'content': 'Grounded tone.', 'constant': true},
                  {
                    'keys': ['x'],
                    'content': '  ',
                  },
                ],
              },
            },
          }),
        );
      final got = await VocesImport.importFile(f, lib);
      final c = got.character!;
      expect(c.id, 'mira');
      expect(c.name, 'Mira');
      expect(c.line, 'A smuggler captain.');
      expect(c.sections.map((s) => s.heading), contains('Who they are'));
      expect(c.sections.map((s) => s.heading), contains('Their world'));
      expect(
        c.sections.expand((s) => [s.text]).join(),
        isNot(contains('You are an AI')),
      );
      final book = got.lorebook!;
      expect(book.name, "Mira's lore");
      expect(book.entries, hasLength(2));
      expect(book.entries.first.title, 'The light');
      expect(book.entries.first.text, 'The light never goes dark.');
      expect(book.entries.last.always, isTrue);
      expect((await lib.characters()).single.name, 'Mira');
      expect((await lib.lorebooks()).single.entries, hasLength(2));
    });

    test('SillyTavern world info becomes a lorebook', () async {
      final f = File(p.join(tmp.path, 'Ember Coast.json'))
        ..writeAsStringSync(
          jsonEncode({
            'entries': {
              '0': {
                'key': ['crown', 'tax'],
                'content': 'The Crown taxes everything.',
                'comment': 'The Crown',
              },
              '1': {
                'key': ['old'],
                'content': 'Gone.',
                'disable': true,
              },
            },
          }),
        );
      final got = await VocesImport.importFile(f, lib);
      expect(got.character, isNull);
      expect(got.lorebook!.name, 'Ember Coast');
      expect(got.lorebook!.entries.first.keys, ['crown', 'tax']);
      expect(got.lorebook!.entries.last.enabled, isFalse);
    });

    test('a file with neither is refused', () async {
      final f = File(p.join(tmp.path, 'x.json'))..writeAsStringSync('[1,2]');
      expect(
        () => VocesImport.importFile(f, lib),
        throwsA(isA<ImportException>()),
      );
    });
  });

  test(
    'each new world and character gets its own colours, kept on edits',
    () async {
      final a = await lib.saveWorld(const VocesWorld(id: '', name: 'Ember'));
      final b = await lib.saveWorld(const VocesWorld(id: '', name: 'Ember'));
      expect(a.art, isNotNull);
      expect(a.art, isNot(b.art));
      final edited = await lib.saveWorld(a.copyWith(line: 'Changed'));
      expect(edited.art, a.art);
      expect((await lib.worlds()).first.art, a.art);
      final c = await lib.saveCharacter(
        const VocesCharacter(id: '', name: 'Mira'),
      );
      expect(c.art, isNotNull);
    },
  );

  test('a picture can be replaced and removed', () async {
    final c = await lib.saveCharacter(
      const VocesCharacter(id: '', name: 'Mira'),
    );
    final png = File(p.join(tmp.path, 'a.png'))..writeAsBytesSync([1, 2]);
    final jpg = File(p.join(tmp.path, 'b.jpg'))..writeAsBytesSync([3]);
    await lib.adoptPortrait(c.id, png);
    final name = await lib.adoptPortrait(c.id, jpg);
    expect(name, 'portrait.jpg');
    final folder = Directory(lib.characterFolder(c.id));
    expect(folder.listSync().map((f) => p.basename(f.path)).toSet(), {
      'character.json',
      'portrait.jpg',
    });
    // Adopting its own file again keeps it.
    await lib.adoptPortrait(c.id, File(p.join(folder.path, 'portrait.jpg')));
    expect(File(p.join(folder.path, 'portrait.jpg')).readAsBytesSync(), [3]);
    await lib.removePortrait(c.id);
    expect(folder.listSync().map((f) => p.basename(f.path)), [
      'character.json',
    ]);
  });

  test('Draw it starts from the world and the character', () {
    final world = worldPrompt(
      tags: ['Fantasy', 'Cosy'],
      line: 'A smugglers\' harbour.',
      setting: 'Salt and lantern light. The Crown taxes all.',
    );
    expect(world, startsWith('scenery, wide shot, no humans'));
    expect(world, contains('Fantasy, Cosy'));
    expect(world, contains('Salt and lantern light.'));
    expect(world, isNot(contains('Crown')));
    final mira = characterPrompt(
      pronouns: 'she/her',
      looksTags: const [],
      sections: const [
        SheetSection('Who they are', 'Runs the Lantern Run.'),
        SheetSection('Looks', 'Red hair, a scar over one eye.'),
      ],
    );
    expect(mira, contains('1girl'));
    expect(mira, contains('Red hair, a scar over one eye.'));
    expect(mira, isNot(contains('Lantern Run')));
    // Picture tags win over the prose.
    final vex = characterPrompt(
      pronouns: 'she/her',
      looksTags: const ['black hair', 'undercut', 'purple hair', 'tattoos'],
      sections: const [SheetSection('Looks', 'Standing six-foot-one…')],
    );
    expect(
      vex,
      'portrait, upper body, solo, 1girl, looking at viewer, '
      'black hair, undercut, purple hair, tattoos',
    );
    expect(
      characterPrompt(
        pronouns: 'they/them',
        looksTags: const [],
        sections: const [],
      ),
      'portrait, upper body, solo, looking at viewer',
    );
  });

  test('picture tags come out of a sheet and a tags-only answer', () {
    final d = CharacterDescriber.parse('''
Name: Vex
Pronouns: she/her
Line: A towering goth e-girl.
Traits: muscular, sardonic
Looks:
Standing six-foot-one with jet-black hair shaved on one side.
Physical tags:
very tall, muscular female, black hair, undercut, purple hair, arm tattoo, fishnet pantyhose, combat boots, septum piercing
How they talk:
Dry. "Sure, champ."
''')!;
    expect(d.looksTags, [
      'very tall',
      'muscular female',
      'black hair',
      'undercut',
      'purple hair',
      'arm tattoo',
      'fishnet pantyhose',
      'combat boots',
      'septum piercing',
    ]);
    expect(d.sections.map((s) => s.heading), ['Looks', 'How they talk']);
    expect(
      LooksTags.parse(
        '<think>hm</think>Long_Hair, Blue Eyes, blue eyes, '
        'a very long sentence that is not a tag at all.',
      ),
      ['long hair', 'blue eyes'],
    );
  });

  test('a card with tag-style looks brings picture tags', () {
    expect(
      VocesImport.looksTagsOf({
        'age': '25',
        'hair': 'black hair, Undercut',
        'wears': 'fishnet pantyhose, combat boots',
        'eyes': '',
      }),
      ['black hair', 'undercut', 'fishnet pantyhose', 'combat boots'],
    );
    expect(
      VocesImport.looksTagsOf({
        'details': 'She has a long scar that runs from her ear to her chin.',
      }),
      isEmpty,
    );
  });

  test('Describe it writes for adults only when asked', () {
    for (final adult in [false, true]) {
      final w = WorldDescriber.instructions(adult: adult);
      final c = CharacterDescriber.instructions(adult: adult);
      expect(w.contains('explicitly and in full'), adult);
      expect(c.contains('explicitly and in full'), adult);
      expect(c.contains('sexuality, desires and kinks'), adult);
      expect(
        CharacterDescriber.brief('a pit fighter', adult: adult),
        adult
            ? 'Idea: a pit fighter\nFor adults (18+).'
            : 'Idea: a pit fighter',
      );
    }
  });

  test('picture tags survive saving', () {
    const c = VocesCharacter(
      id: 'vex',
      name: 'Vex',
      looksTags: ['black hair', 'undercut'],
    );
    expect(VocesCharacter.fromJson(c.toJson()).looksTags, [
      'black hair',
      'undercut',
    ]);
    expect(
      VocesCharacter.fromJson(
        const VocesCharacter(id: 'a', name: 'A').toJson(),
      ).looksTags,
      isEmpty,
    );
  });

  test('a draft keeps what was typed and a drawn picture', () async {
    final key = VocesLibrary.draftKey('world', null);
    expect(key, 'world-new');
    expect(lib.draft(key), isNull);
    final drawn = File(p.join(lib.drawingFolder, 'try-1.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final kept = lib.keepDraft(
      key,
      const VocesWorld(id: '', name: 'Moonwell').toJson(),
      picture: drawn,
    );
    // Moved out of the drawing folder, which is cleared.
    expect(p.isWithin(lib.draftsFolder, kept!.path), isTrue);
    expect(drawn.existsSync(), isFalse);
    final d = lib.draft(key)!;
    expect(VocesWorld.fromJson(d.item).name, 'Moonwell');
    expect(d.picture!.readAsBytesSync(), [1, 2, 3]);
    expect(await lib.draftKeys(), {'world-new'});
    await lib.dropDraft(key);
    expect(lib.draft(key), isNull);
    expect(kept.existsSync(), isFalse);
  });
}
