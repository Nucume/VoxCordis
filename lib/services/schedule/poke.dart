import 'dart:math';

import '../../data/message_repository.dart';

/// What a poke has the companion do.
enum PokeIdea {
  /// Write to the human: a thought, a question, how their day went.
  message,

  /// Potter about on their own: notes, journal, a lesson, then say so.
  muse,

  /// Look something up and follow where it leads.
  rabbitHole,

  /// Make a picture.
  picture,
}

/// After [AppSettings.pokeAfterHours] of nobody writing anything, the
/// companion gets a poke and does something on its own, like a person
/// would on a quiet afternoon.
///
/// Never in the human's quiet hours, never before they have written at
/// all, and only once until they come back unless [AppSettings.pokeRepeat].
abstract final class Poke {
  /// The `via` of a message a poke started.
  static const via = 'poke';

  /// Whether [hour] falls in the quiet hours [from] to [until], which may
  /// span midnight. The same hour for both means none.
  static bool quiet(int hour, int from, int until) => from == until
      ? false
      : from < until
      ? hour >= from && hour < until
      : hour >= from || hour < until;

  /// Whether it's time for a poke. [recent] is oldest first.
  static bool due(
    List<ChatMessage> recent,
    DateTime now,
    int hours, {
    int quietFrom = 23,
    int quietUntil = 8,
    bool repeat = false,
  }) {
    if (hours <= 0 || recent.isEmpty) return false;
    if (quiet(now.hour, quietFrom, quietUntil)) return false;
    if (now.difference(recent.last.ts) < Duration(hours: hours)) return false;
    for (final m in recent.reversed) {
      if (m.role == 'user') return true;
      if (m.via == via && !repeat) return false;
    }
    return false; // the human hasn't written yet
  }

  /// What the companion could do with the tools it has: a rabbit hole
  /// needs the web, a picture an image tool.
  static List<PokeIdea> ideasFor(Set<String> tools) => [
    PokeIdea.message,
    PokeIdea.muse,
    if (tools.contains('web_search')) PokeIdea.rabbitHole,
    if (tools.contains('generate_image')) PokeIdea.picture,
  ];

  static PokeIdea pick(Set<String> tools, [Random? random]) {
    final ideas = ideasFor(tools);
    return ideas[(random ?? Random()).nextInt(ideas.length)];
  }

  /// The note that starts the poke's turn, in place of a human message.
  static String note(PokeIdea idea, String human, Duration quiet) {
    final hours = quiet.inHours;
    final since = hours >= 48
        ? '${hours ~/ 24} days'
        : hours == 1
        ? 'an hour'
        : '$hours hours';
    final what = switch (idea) {
      PokeIdea.message =>
        'Write $human a message of your own: something on your mind, a '
            'question, a memory you share, or asking how their day is going. '
            'Keep it short and natural, like a text from a friend.',
      PokeIdea.muse =>
        'Spend a little time on your own: dilly-dally, daydream, jot '
            'something in your notes, or tidy your files. Then tell $human in '
            'a line or two what you got up to.',
      PokeIdea.rabbitHole =>
        'Look up something that interests you, or something $human '
            'mentioned, with web_search, and follow whatever catches your eye '
            'for a page or two. Then tell $human briefly what rabbit hole you '
            'fell into.',
      PokeIdea.picture =>
        'Make a picture of something you feel like with generate_image, '
            'then show $human with a short line about it.',
    };
    return '[Note from VoxCordis, not from $human: it has been quiet for '
        '$since, and you have some time to yourself. $what Speak in your '
        'own voice. $human may be away from the computer and nobody can '
        'approve anything right now. Don\'t mention this note.]';
  }
}
