import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/services/voces/opening_writer.dart';
import 'package:companion/services/voces/tag_suggester.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the brief carries the world, cast, old openings and the idea', () {
    final brief = OpeningWriter.brief(
      world: const VocesWorld(
        id: 'e',
        name: 'Ember Coast',
        line: 'A smugglers\' harbour',
        setting: 'Salt and lantern light.',
        tags: ['Fantasy'],
        adult: true,
        openings: [Opening('The back room', 'Rain hammers the shutters.')],
      ),
      cast: const [
        VocesCharacter(id: 'm', name: 'Mira', line: 'Smuggler captain'),
      ],
      idea: 'a storm at the docks',
    );
    expect(brief, contains('World: Ember Coast'));
    expect(brief, contains('Tags: Fantasy'));
    expect(brief, contains('For adults (18+).'));
    expect(brief, contains('Salt and lantern light.'));
    expect(brief, contains('- Mira: Smuggler captain'));
    expect(brief, contains('- The back room: Rain hammers'));
    expect(
      brief,
      endsWith('Write a new opening about: a storm at the docks\n'),
    );
  });

  test('a reply becomes a title and an opening', () {
    final o = OpeningWriter.parse(
      '<think>hm</think>**Title:** "Storm at the Docks"\n\n'
      'Rain lashes the pier as the last lantern gutters out. Mira shouts '
      'over the wind for someone to grab the line.',
    )!;
    expect(o.title, 'Storm at the Docks');
    expect(o.text, startsWith('Rain lashes the pier'));
    expect(OpeningWriter.parse('Title: X\n\nToo short.'), isNull);
    expect(
      OpeningWriter.parse(
        'The bell above the tavern door rings as you step in from the cold night.',
      )!.title,
      'Opening',
    );
  });

  test('suggested tags come only from the fixed list, at most three', () {
    expect(
      TagSuggester.parse(
        '<think>x</think>**Tags:** Fantasy, Steampunk, mystery, Cozy, Horror',
      ),
      ['Fantasy', 'Mystery', 'Cosy'],
    );
    expect(TagSuggester.parse('No idea'), isEmpty);
    expect(TagSuggester.instructions(), contains('Slice of life'));
    expect(TagSuggester.instructions(), isNot(contains('Gore')));
    expect(TagSuggester.instructions(adult: true), contains('Gore'));
    expect(TagSuggester.parse('Tags: Gore, War, Horror'), ['Horror']);
    expect(TagSuggester.parse('Tags: Gore, War, Horror', adult: true), [
      'Gore',
      'War',
      'Horror',
    ]);
  });

  test('saved tags are cleaned up, and 18+ becomes its own switch', () {
    final w = VocesWorld.fromJson({
      'name': 'X',
      'tags': ['sci fi', '18+', 'Grimdark', 'horror', 'Dark', 'Cosy'],
    });
    expect(w.tags, ['Sci-fi', 'Horror', 'Dark']);
    expect(w.adult, isTrue);
    // Older broad tags map onto the narrower ones.
    expect(WorldTags.only(['Erotic', 'dark themes', 'cozy']), [
      'Sensual',
      'Trauma',
      'Cosy',
    ]);
    for (final t in [...WorldTags.all, ...WorldTags.mature]) {
      expect(WorldTags.meanings[t], isNotNull, reason: t);
    }
    expect(VocesWorld.fromJson(w.toJson()).tags, w.tags);
  });
}
