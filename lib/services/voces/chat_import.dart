import '../../data/voces/story_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../import/soulkyn_chat.dart';
import 'story_engine.dart';

/// Turns a Soulkyn chat into a Voces Mundi story to go on with: a world
/// (the Kyn's scenario as its setting), the human's character, and every
/// message as a turn.
class VocesChatImport {
  /// The log state key of the last turn looked through for people, in a
  /// story that came from a chat: the story finds the people of the old
  /// chat after it opens, a part at a time.
  static const peopleAtKey = 'importPeopleAt';

  /// Saves the story and returns it. [world] is an existing world to play
  /// it in; without one a new world is made from the chat, run by the
  /// narrator when [narratorLed] (the Kyn plays everyone), else with the
  /// Kyn as its one character. [player] is who the human plays; without one
  /// a character with the name they went by is made.
  static Future<StorySave> save(
    SoulkynChat chat,
    VocesLibrary library, {
    required Future<StoryLog> Function(String storyId) openLog,
    VocesWorld? world,
    bool narratorLed = true,
    bool adult = false,
    VocesCharacter? player,
    String? title,
    DateTime? now,
  }) async {
    const source = 'a Soulkyn chat';
    String? kynId;
    if (world == null) {
      VocesCharacter? kyn;
      if (!narratorLed) {
        kyn = await library.saveCharacter(
          VocesCharacter(
            id: '',
            name: chat.kynName,
            line: 'From a Soulkyn chat',
            source: source,
            created: now,
          ),
        );
      }
      world = await library.saveWorld(
        VocesWorld(
          id: '',
          name: chat.kynName,
          line: 'From a Soulkyn chat',
          setting: chat.intro,
          adult: adult,
          narratorLed: narratorLed,
          castIds: [?kyn?.id],
          openings: [
            if (chat.opening case final o?) Opening('From Soulkyn', o),
          ],
          source: source,
          created: now,
        ),
      );
      kynId = kyn?.id;
    } else {
      // The Kyn speaks as someone of the world's cast by the same name,
      // else as the narrator.
      for (final c in await library.characters()) {
        if (world.castIds.contains(c.id) &&
            c.name.toLowerCase() == chat.kynName.toLowerCase()) {
          kynId = c.id;
        }
      }
    }
    player ??= await library.saveCharacter(
      VocesCharacter(
        id: '',
        name: chat.persona,
        line: 'Who you played on Soulkyn',
        source: source,
        created: now,
      ),
    );
    var story = await library.startStory(
      world: world,
      player: player,
      title: title ?? chat.kynName,
      now: now,
    );

    final log = await openLog(story.id);
    var place = '';
    var told = 0;
    try {
      for (final l in chat.lines) {
        final TurnKind kind;
        if (l.fromKyn) {
          kind = kynId == null ? TurnKind.narrator : TurnKind.character;
          place = SoulkynChat.placeIn(l.text) ?? place;
        } else {
          kind = l.text.startsWith('*') ? TurnKind.act : TurnKind.say;
        }
        await log.add(
          kind,
          l.text,
          speakerId: l.fromKyn ? kynId : null,
          speaker: l.fromKyn && kynId != null ? chat.kynName : '',
          now: l.ts.toLocal(),
        );
        told++;
      }
      await log.setState(
        'story',
        StoryState(present: [?kynId], place: place).toJson(),
      );
      await log.setState(peopleAtKey, 0);
    } finally {
      await log.close();
    }
    story = await library.saveStory(
      story.copyWith(
        turns: told,
        place: place,
        lastPlayed: chat.last.toLocal(),
      ),
    );
    return story;
  }
}
