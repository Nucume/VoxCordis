import '../../data/skills/booru_tags.dart';
import '../../data/voces/story_log.dart';
import '../../data/voces/voces_models.dart';
import 'describer.dart';
import 'story_engine.dart';

/// "Draw the scene": the chat model reads the last turns and answers with
/// who is in view and picture tags for the moment; each one in view adds
/// their own Physical tags, so they look the same in every picture.
abstract final class SceneTags {
  /// How many turns before the picked one are read.
  static const readTurns = 6;

  /// Tags the model may give for the scene itself.
  static const max = 40;

  /// The tag groups from the booru skill that help with a scene: framing,
  /// poses, hands and light (and, for 18+ worlds, the explicit ones).
  static List<String> referenceFiles({required bool adult}) => [
    'tags/image-composition.md',
    'tags/posture.md',
    'tags/gestures.md',
    'tags/lighting.md',
    if (adult) ...[
      'tags/nudity.md',
      'tags/sex-acts.md',
      'tags/sexual-positions.md',
    ],
  ];

  static String instructions({required bool adult}) {
    final refs = [
      for (final f in referenceFiles(adult: adult))
        if (booruTagFiles[f] case final text?) text.trim(),
    ].join('\n\n');
    return '''
You turn a moment of a story into a picture prompt for an anime image model
trained on Danbooru tags.

Answer with exactly two lines and nothing else:
Visible: the names of the characters seen in the picture, comma separated (or "none")
Tags: 15 to 40 comma separated Danbooru-style tags, lowercase

The tags describe what can be seen at this moment: how many people and
their genders first (1girl, 2girls, 1boy, 1girl 1boy, solo, no humans),
then framing and camera angle, what each one is doing (pose, gesture,
expression), where it happens and what is around them, time of day,
weather and light. Leave out hair, eyes, body and clothes of the named
characters: their own tags are added. Do add clothes that changed in the
story (wet clothes, torn clothes, naked). No names, no sentences, no
quality tags.
${adult ? '''
This is for adults (18+): explicit tags are fine when the moment is
explicit. Everyone in anything sexual is an adult.
''' : '''
Keep it safe for work: nothing sexual or gory, even when the story hints
at it.
'''}
Tags that work well, by group:

$refs''';
  }

  /// What the model reads: the people, the place and the last turns up to
  /// [upTo] (included).
  static String brief(
    StoryEngine engine,
    List<StoryTurn> turns,
    StoryTurn upTo, {
    String? place,
  }) {
    final end = turns.indexWhere((t) => t.id == upTo.id);
    final until = end < 0 ? turns : turns.sublist(0, end + 1);
    final recent = [
      for (final t
          in until.reversed.where((t) => !t.kind.aside).take(readTurns))
        t,
    ].reversed.toList();
    final people = engine.world.cast.values;
    return [
      'People in the story:',
      for (final c in people)
        '- ${c.name}${c.pronouns == null || c.pronouns!.isEmpty ? '' : ' (${c.pronouns})'}'
            '${c.id == engine.world.story.playerId ? ', played by the human' : ''}',
      if (place != null && place.trim().isNotEmpty) 'Place: ${place.trim()}',
      if (engine.world.world.setting.trim().isNotEmpty)
        'World: ${_cut(engine.world.world.setting, 400)}',
      '',
      'The moment to draw is the last part of this:',
      engine.transcript(recent),
      '',
      // Said last as well: a roleplay model reading a story otherwise tends
      // to write the story on.
      'Do not continue the story. Answer only with the two lines, '
          '"Visible:" and "Tags:".',
    ].join('\n');
  }

  /// The prompt from the model's [reply]: its tags, then each visible
  /// character's Physical tags. Empty when the reply has no tags.
  static String prompt(String reply, Iterable<VocesCharacter> cast) {
    final clean = reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final head = RegExp(
      r'^[#*\s-]*(visible|tags)[*\s]*:[*\s]*',
      caseSensitive: false,
      multiLine: true,
    );
    // Each field runs to the next one, so tags on lines of their own (a
    // list under "Tags:") count too.
    final heads = head.allMatches(clean).toList();
    String? field(String name) {
      for (var i = 0; i < heads.length; i++) {
        if (heads[i].group(1)!.toLowerCase() != name) continue;
        final end = i + 1 < heads.length ? heads[i + 1].start : clean.length;
        return clean.substring(heads[i].end, end).trim();
      }
      return null;
    }

    final tagLine = field('tags') ?? _tagLines(clean);
    final tags = LooksTags.parse(
      tagLine,
      max: max,
    ).where((t) => !t.startsWith('visible')).toList();
    if (tags.isEmpty) return '';
    final visible = (field('visible') ?? '')
        .toLowerCase()
        .split(',')
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toSet();
    final looks = [
      for (final c in cast)
        if (visible.contains(c.name.toLowerCase()) ||
            visible.contains(c.name.toLowerCase().split(' ').first))
          if (c.looksTags.isNotEmpty) c.looksTags.join(', '),
    ];
    return [tags.join(', '), ...looks].join(', ');
  }

  /// The lines of [text] that read as tag lists (several short,
  /// comma-separated items), when a model left out the "Tags:" label.
  static String _tagLines(String text) => [
    for (final l in text.split('\n'))
      if (l.split(',') case final items
          when items.length >= 3 &&
              items.every((i) => i.trim().split(RegExp(r'\s+')).length <= 4))
        l,
  ].join(', ');

  static String _cut(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max).trimRight()}…';
  }
}
