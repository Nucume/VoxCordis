import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/data/voces/story_log.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/guests.dart';
import 'package:companion/services/voces/living_cast.dart';
import 'package:companion/services/voces/story_engine.dart';

StoryTurn turn(int id, TurnKind kind, String text, {String? by}) => StoryTurn(
  id: id,
  kind: kind,
  text: text,
  speakerId: by,
  speaker: by ?? '',
  ts: DateTime(2026, 11, 16),
);

List<StoryTurn> told(int n) => [
  for (var i = 1; i <= n; i++) turn(i, TurnKind.narrator, 'Waves.'),
];

void main() {
  const mira = VocesCharacter(id: 'mira', name: 'Mira', line: 'Kiosk owner');
  const haru = VocesCharacter(id: 'haru', name: 'Haru', line: 'Surfer');
  const aurora = VocesCharacter(
    id: 'aurora',
    name: 'Aurora Skye',
    line: 'Bubbly university student who loves swimming',
    tags: ['party animal', 'athletic'],
  );
  const knight = VocesCharacter(
    id: 'knight',
    name: 'Ser Aldric',
    line: 'A sworn knight of the dragon crown',
    tags: ['honourable', 'grim'],
  );
  const homebody = VocesCharacter(
    id: 'home',
    name: 'Quill',
    line: 'Only makes sense in his tower',
    visits: false,
  );
  const lewd = VocesCharacter(id: 'lewd', name: 'Velvet', line: 'Club host');
  const beach = VocesWorld(
    id: 'bks',
    name: 'BKS Beachside Kiosk',
    line: 'A kiosk on a sunny beach by the university',
    setting: 'Students swimming, surfing and partying by the sea.',
    tags: ['Slice of life', 'Comedy'],
    castIds: ['mira'],
    guests: GuestRule.anyone,
  );
  const realm = VocesWorld(
    id: 'realm',
    name: 'Dragon Realm',
    tags: ['Fantasy'],
    castIds: ['knight'],
  );
  const club = VocesWorld(
    id: 'club',
    name: 'Velvet Club',
    adult: true,
    castIds: ['lewd'],
  );
  final worlds = [beach, realm, club];
  final library = [mira, haru, aurora, knight, homebody, lewd];
  final save = StorySave(
    id: 's',
    title: 'Haru at the kiosk',
    worldId: 'bks',
    worldName: beach.name,
    playerId: 'haru',
    playerName: 'Haru',
    created: DateTime(2026, 11, 16),
    lastPlayed: DateTime(2026, 11, 16),
  );
  StoryWorld storyOf(VocesWorld w) => StoryWorld(
    story: save,
    world: w,
    cast: {'mira': mira, 'haru': haru},
    lorebooks: const [],
    folder: '/nowhere',
  );

  List<String> allowed(
    VocesWorld rules, {
    StoryState state = const StoryState(),
    bool mature = true,
    VocesWorld? host,
  }) => [
    for (final c in Guests.allowed(
      rules: rules,
      story: storyOf(host ?? rules),
      state: state,
      library: library,
      worlds: worlds,
      mature: mature,
    ))
      c.id,
  ];

  group('saved', () {
    test('worlds keep their guest rules; older worlds are closed', () {
      final w = VocesWorld.fromJson(
        beach.copyWith(barredIds: ['knight']).toJson(),
      );
      expect(w.guests, GuestRule.anyone);
      expect(w.barredIds, ['knight']);
      final old = VocesWorld.fromJson({'id': 'x', 'name': 'Old'});
      expect(old.guests, GuestRule.none);
      expect(old.guestIds, isEmpty);
      expect(old.toJson().containsKey('guests'), isFalse);
    });

    test('characters visit unless told not to', () {
      expect(VocesCharacter.fromJson({'name': 'A'}).visits, isTrue);
      expect(VocesCharacter.fromJson(homebody.toJson()).visits, isFalse);
      expect(aurora.toJson().containsKey('visits'), isFalse);
      expect(homebody.copyWith(name: 'Q').visits, isFalse);
    });

    test('a story keeps its own switch and its guests', () {
      final s = StoryState.fromJson(
        const StoryState(
          guests: true,
          guestIds: {'aurora'},
          guestAt: 12,
        ).toJson(),
      );
      expect(s.guests, isTrue);
      expect(s.guestIds, {'aurora'});
      expect(s.guestAt, 12);
      // Back to following the world.
      expect(s.copyWith(guests: () => null).guests, isNull);
      expect(s.copyWith(chain: 1).guests, isTrue);
      expect(StoryState.fromJson(const {}).guests, isNull);
    });
  });

  test('open: the story\'s switch wins over the world', () {
    expect(Guests.open(beach, const StoryState()), isTrue);
    expect(Guests.open(realm, const StoryState()), isFalse);
    expect(Guests.open(realm, const StoryState(guests: true)), isTrue);
    expect(Guests.open(beach, const StoryState(guests: false)), isFalse);
  });

  group('who may turn up', () {
    test('never the player, the cast, nor who stays home', () {
      // Velvet is left out too: she is only in an 18+ world.
      expect(allowed(beach), ['aurora', 'knight']);
    });

    test('nobody barred, and only those picked', () {
      expect(allowed(beach.copyWith(barredIds: ['knight'])), ['aurora']);
      expect(
        allowed(beach.copyWith(guests: GuestRule.picked, guestIds: ['aurora'])),
        ['aurora'],
      );
    });

    test('18+ guard', () {
      // Velvet is cast only in the 18+ club.
      final adultBeach = beach.copyWith(adult: true);
      expect(allowed(adultBeach), contains('lewd'));
      expect(allowed(beach).contains('lewd'), isFalse);
      // Mature content off: not even in an 18+ world.
      expect(allowed(adultBeach, mature: false).contains('lewd'), isFalse);
    });

    test('a story switched on in a closed world lets in anyone not barred', () {
      final closed = beach.copyWith(
        guests: GuestRule.none,
        barredIds: ['knight'],
      );
      expect(allowed(closed, state: const StoryState(guests: true)), [
        'aurora',
      ]);
    });

    test('nobody already in the story under the same name', () {
      expect(
        allowed(
          beach,
          state: const StoryState(extras: [Extra('Aurora Skye', 'a swimmer')]),
        ).contains('aurora'),
        isFalse,
      );
    });
  });

  test('the best fits first, by the words they share', () {
    final scene = Guests.scene(
      beach,
      'the beach',
      'Students are swimming near the kiosk.',
    );
    final people = [knight, aurora];
    final scores = [
      for (final c in people)
        Guests.wordScore(scene, Guests.profile(c, worlds)),
    ];
    expect(scores[1], greaterThan(scores[0]));
    final best = Guests.best(people, scores, Random(3));
    expect(best.first.id, 'aurora');
    expect(
      Guests.best([...library, ...library], List.filled(12, 1), Random(1)),
      hasLength(Guests.offer),
    );
  });

  test('a profile says who they are and where they usually are', () {
    final p = Guests.profile(knight, worlds);
    expect(p, contains('Ser Aldric: A sworn knight'));
    expect(p, contains('Usually in: Dragon Realm (Fantasy)'));
  });

  group('when a guest is due', () {
    test('not in the first turns, and not right after another', () {
      const s = StoryState(liveliness: Liveliness.busy);
      expect(Guests.due(s, told(Guests.pause - 1), 0), isFalse);
      expect(Guests.due(s, told(Guests.pause), 0), isTrue);
      expect(
        Guests.due(s.copyWith(guestAt: 5), told(Guests.pause + 4), 0),
        isFalse,
      );
      expect(
        Guests.due(s.copyWith(guestAt: 5), told(Guests.pause + 5), 0),
        isTrue,
      );
    });

    test('rarer than the cast coming and going', () {
      const s = StoryState();
      final turns = told(20);
      final c = Guests.chance(Liveliness.normal);
      expect(c, lessThan(Liveliness.normal.arrive));
      expect(Guests.due(s, turns, c - 0.001), isTrue);
      expect(Guests.due(s, turns, c + 0.001), isFalse);
    });

    test('not when the scene already has a crowd of guests', () {
      const s = StoryState(present: ['a', 'b'], guestIds: {'a', 'b'});
      expect(Guests.due(s, told(30), 0), isFalse);
      expect(Guests.due(s.copyWith(present: ['a']), told(30), 0), isTrue);
    });
  });

  test('the model\'s pick', () {
    final c = [aurora, knight];
    expect(Guests.parsePick('Aurora Skye', c)?.id, 'aurora');
    expect(Guests.parsePick('aurora', c)?.id, 'aurora');
    expect(
      Guests.parsePick('<think>Ser Aldric? no.</think>Aurora', c)?.id,
      'aurora',
    );
    expect(Guests.parsePick('None.', c), isNull);
    expect(Guests.parsePick('none of them, maybe Aurora later', c), isNull);
    expect(
      Guests.parsePick('Aurora Skye fits; none of the others.', c)?.id,
      'aurora',
    );
    expect(Guests.parsePick('Someone else', c), isNull);
    expect(Guests.parsePick('', c), isNull);
  });

  test('the brief offers the candidates and the scene, nothing more', () {
    final b = Guests.pickerBrief(
      world: beach,
      place: 'The kiosk',
      recent: 'Mira wipes the counter.',
      candidates: [aurora],
      worlds: worlds,
    );
    expect(b, contains('BKS Beachside Kiosk'));
    expect(b, contains('Where: The kiosk'));
    expect(b, contains('Mira wipes the counter.'));
    expect(b, contains('- Aurora Skye: Bubbly'));
    expect(b, isNot(contains('Ser Aldric')));
  });

  group('prompts', () {
    final story = StoryWorld(
      story: save,
      world: beach,
      cast: {'mira': mira, 'haru': haru, 'aurora': aurora},
      lorebooks: const [],
      folder: '/nowhere',
    );
    final engine = StoryEngine(story, mature: false, random: Random(1));
    final turns = [turn(1, TurnKind.narrator, 'Sun on the sand.')];

    test('nobody is offered to the narrator before they arrive', () {
      final pr = engine.prompt(
        null,
        turns,
        const StoryState(present: ['mira']),
      );
      expect(pr.system, isNot(contains('Aurora')));
      expect(pr.user, isNot(contains('Aurora')));
    });

    test('a guest arriving is fitted into the world', () {
      final pr = engine.prompt(
        null,
        turns,
        const StoryState(present: ['mira', 'aurora'], guestIds: {'aurora'}),
        change: const CastChange(aurora, arrives: true, guest: true),
      );
      expect(pr.user, contains('Aurora Skye'));
      expect(pr.user, contains('belong in BKS Beachside Kiosk'));
      expect(pr.system, contains('came from other stories'));
    });

    test('a guest speaking leaves their home\'s rules at home', () {
      const s = StoryState(present: ['mira', 'aurora'], guestIds: {'aurora'});
      expect(
        engine.prompt('aurora', turns, s).system,
        contains('wasn\'t made for BKS Beachside Kiosk'),
      );
      expect(
        engine.prompt('mira', turns, s).system,
        isNot(contains('wasn\'t made for')),
      );
    });
  });

  group('library', () {
    late Directory tmp;
    late VocesLibrary lib;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('guests');
      lib = VocesLibrary(tmp.path);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('a guest is copied into the story, portrait and all', () async {
      final a = await lib.saveCharacter(aurora);
      await File(
        p.join(lib.characterFolder(a.id), 'portrait.png'),
      ).writeAsBytes([1, 2, 3]);
      final saved = await lib.saveCharacter(
        a.copyWith(portrait: 'portrait.png'),
      );
      final w = await lib.saveWorld(beach.copyWith(castIds: []));
      final h = await lib.saveCharacter(haru);
      final story = await lib.startStory(world: w, player: h, title: 'T');
      final guest = await lib.addGuest(story, saved);
      expect(guest.id, saved.id);
      final sw = await lib.storyWorld(story);
      expect(sw.cast[guest.id]?.name, 'Aurora Skye');
      expect(sw.portraitOf(sw.cast[guest.id]!)!.existsSync(), isTrue);

      // Someone else already under that id in the story: a new one.
      await lib.saveStoryCharacter(
        story,
        const VocesCharacter(id: 'other', name: 'Other'),
      );
      final clash = await lib.addGuest(
        story,
        saved.copyWith(id: 'other', name: 'Aurora Skye'),
      );
      expect(clash.id, isNot('other'));
      final again = await lib.storyWorld(story);
      expect(again.cast['other']?.name, 'Other');
      expect(again.cast[clash.id]?.name, 'Aurora Skye');
    });
  });
}
