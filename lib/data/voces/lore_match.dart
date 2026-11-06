import 'voces_models.dart';

/// Which lorebook entries a piece of story brings into the prompt.
///
/// An entry comes in when one of its key words appears in the text as a
/// whole word (any case), or always when it is marked so. Matching by
/// meaning joins this once stories are played (see the Recall service).
class LoreMatch {
  /// The entries of [entries] that [text] calls up, in their order.
  static List<LoreEntry> match(String text, Iterable<LoreEntry> entries) => [
    for (final e in entries)
      if (e.enabled && (e.always || hits(text, e))) e,
  ];

  /// Whether a key word of [entry] is in [text].
  static bool hits(String text, LoreEntry entry) {
    final t = text.toLowerCase();
    for (final key in entry.keys) {
      final k = key.trim().toLowerCase();
      if (k.isEmpty) continue;
      // Whole words only: "art" shouldn't wake an entry on "party".
      final pattern = RegExp(
        '(?<![\\p{L}\\p{N}])${RegExp.escape(k)}(?![\\p{L}\\p{N}])',
        unicode: true,
      );
      if (pattern.hasMatch(t)) return true;
    }
    return false;
  }
}

/// One thing search found.
sealed class VocesHit {
  const VocesHit();
}

class WorldHit extends VocesHit {
  const WorldHit(this.world);
  final VocesWorld world;
}

class CharacterHit extends VocesHit {
  const CharacterHit(this.character);
  final VocesCharacter character;
}

class LoreHit extends VocesHit {
  const LoreHit(this.book, this.entry);
  final Lorebook book;
  final LoreEntry entry;
}

/// The sidebar's search: worlds, then characters, then lore entries whose
/// text holds every word of [query].
List<VocesHit> searchVoces(
  String query, {
  required List<VocesWorld> worlds,
  required List<VocesCharacter> characters,
  required List<Lorebook> lorebooks,
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  bool found(String hay) {
    final h = hay.toLowerCase();
    return words.every(h.contains);
  }

  return [
    for (final w in worlds)
      if (found(w.searchText)) WorldHit(w),
    for (final c in characters)
      if (found(c.searchText)) CharacterHit(c),
    for (final b in lorebooks)
      for (final e in b.entries)
        if (found('${e.title} ${e.keys.join(' ')} ${e.text} ${b.name}'))
          LoreHit(b, e),
  ];
}
