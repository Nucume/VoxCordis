import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/services/import/scenario_split.dart';
import 'package:companion/services/import/voces_import.dart';

const _scenario = '''
You wake in the hold of the Gull, a smuggler ship bound for Ember Coast.
The sea is grey and the Crown's cutters are close.

## Characters
- **Mira Vane** (34): captain of the Gull, dry and quick, owes the wrong people money.
- Tomas: a dockhand of seventeen who knows every hiding place on the ship.
- Note: the narrator plays everyone else.

## The Lantern Guild
The Lantern Guild keeps the lighthouses lit and takes a tithe of every cargo. Its masters meet in the Glass Hall at Ember Point. The Guild hates the Crown, and the Crown hates the Guild, and Ember Point sits between them.

## Rules
Track the ship's damage from 0 to 10. At 10 the Gull sinks. The Crown's cutters arrive when the alarm bell rings three times.
''';

void main() {
  test('a scenario splits into setting, lore and people', () {
    final s = ScenarioSplit.of(_scenario * 1);
    expect(s.people.map((p) => p.name), ['Mira Vane', 'Tomas']);
    expect(s.people.first.text, startsWith('captain of the Gull'));
    expect(s.setting, contains('You wake in the hold'));
    // Short enough to stay whole in the setting.
    expect(s.setting, contains('Lantern Guild'));
    expect(s.entries, isEmpty);

    // A long one keeps its start, and the rest becomes lore.
    final long =
        '$_scenario\n## Old history\n${'The coast burned once. ' * 120}';
    final l = ScenarioSplit.of(long);
    expect(l.setting, contains('You wake in the hold'));
    expect(l.setting, isNot(contains('The coast burned')));
    final history = l.entries.singleWhere((e) => e.title == 'Old history');
    expect(history.keys, contains('Old history'));
  });

  test('a scenario without headings splits by paragraphs', () {
    final text = List.generate(
      8,
      (i) => 'Part $i. ${'The Guild of Saltmarsh keeps its secrets. ' * 12}',
    ).join('\n\n');
    final s = ScenarioSplit.of(text);
    expect(s.setting, startsWith('Part 0.'));
    expect(s.entries, isNotEmpty);
    expect(s.entries.first.keys, contains('Guild'));
    expect(s.people, isEmpty);
  });

  test('a Soulkyn RPG card comes in as a narrator-led world', () async {
    final dir = Directory.systemTemp.createTempSync('voces_world_import');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'gull.json'))
      ..writeAsStringSync(
        jsonEncode({
          'data': {
            'name': 'The Gull',
            'extensions': {
              'soulkyn': {
                'card_type': 'rpg',
                'tagline': 'A smuggler run on a stormy coast',
                'background_story':
                    '$_scenario\n## Old history\n${'The coast burned once. ' * 120}',
                'location': ['Ember Coast'],
              },
            },
          },
        }),
      );
    final read = await VocesImport.readFile(file);
    expect(read.looksLikeAGame, isTrue);
    final world = VocesImport.asWorld(read);
    expect(world.world!.narratorLed, isTrue);
    expect(world.world!.name, 'The Gull');
    expect(world.world!.line, 'A smuggler run on a stormy coast');
    expect(world.world!.setting, contains('Places: Ember Coast'));
    expect(world.cast.map((c) => c.name), ['Mira Vane', 'Tomas']);
    expect(world.lorebook!.name, 'The Gull lore');

    final lib = VocesLibrary.inside(dir.path);
    final saved = await VocesImport.save(world, lib);
    final w = (await lib.worlds()).single;
    expect(w.narratorLed, isTrue);
    expect(w.castIds, [for (final c in saved.cast) c.id]);
    expect(w.lorebookIds, [saved.lorebook!.id]);
    expect((await lib.characters()).length, 2);
  });

  test('an ordinary card can be a world too, from its description', () async {
    final dir = Directory.systemTemp.createTempSync('voces_world_import');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'dungeon.json'))
      ..writeAsStringSync(
        jsonEncode({
          'spec': 'chara_card_v2',
          'data': {
            'name': 'Dungeon Master',
            'description': 'A text adventure in the Hollow Deep.',
            'scenario': 'The party stands at the gate.',
            'first_mes': 'The gate creaks open.',
          },
        }),
      );
    final read = await VocesImport.readFile(file);
    expect(read.looksLikeAGame, isFalse);
    final world = VocesImport.asWorld(read);
    expect(world.world!.setting, contains('Hollow Deep'));
    expect(world.world!.setting, contains('stands at the gate'));
    expect(world.world!.openings.single.text, contains('creaks open'));
  });
}
