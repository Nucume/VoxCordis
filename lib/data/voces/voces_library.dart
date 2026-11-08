import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'voces_models.dart';

/// Where Voces Mundi keeps its worlds, characters, lorebooks and stories:
/// `<VoxCordis folder>/Voces Mundi/`, beside the companions.
///
/// ```text
/// Voces Mundi/
///   worlds/<id>/world.json        + its picture
///   characters/<id>/character.json + their portrait
///   lorebooks/<id>.json
///   stories/<id>/story.json       + world.json, cast/, lorebooks/ copied
///                                    when the story began
/// ```
///
/// Plain files, so people can back them up, share them or fix one by hand.
/// A file that can't be read is skipped, never fatal.
class VocesLibrary {
  VocesLibrary(this.root);

  /// The Voces Mundi folder in the VoxCordis folder at [voxRoot].
  factory VocesLibrary.inside(String voxRoot) =>
      VocesLibrary(p.join(voxRoot, folderName));

  static const folderName = 'Voces Mundi';

  final String root;

  String get _worlds => p.join(root, 'worlds');
  String get _characters => p.join(root, 'characters');
  String get _lorebooks => p.join(root, 'lorebooks');
  String get _stories => p.join(root, 'stories');

  String worldFolder(String id) => p.join(_worlds, id);
  String characterFolder(String id) => p.join(_characters, id);
  String storyFolder(String id) => p.join(_stories, id);

  /// A picture or portrait of an item, or null.
  File? worldPicture(VocesWorld w) =>
      w.picture == null ? null : File(p.join(worldFolder(w.id), w.picture));
  File? portraitOf(VocesCharacter c) => c.portrait == null
      ? null
      : File(p.join(characterFolder(c.id), c.portrait));

  // Reading.

  Future<List<VocesWorld>> worlds() => _readAll(
    _worlds,
    (dir) => File(p.join(dir, 'world.json')),
    VocesWorld.fromJson,
  );

  Future<List<VocesCharacter>> characters() => _readAll(
    _characters,
    (dir) => File(p.join(dir, 'character.json')),
    VocesCharacter.fromJson,
  );

  Future<List<Lorebook>> lorebooks() async {
    final dir = Directory(_lorebooks);
    if (!await dir.exists()) return [];
    final books = <Lorebook>[];
    await for (final f in dir.list()) {
      if (f is! File || p.extension(f.path) != '.json') continue;
      final json = await _readJson(f);
      if (json != null) {
        books.add(
          Lorebook.fromJson(
            json,
          ).copyWith(id: p.basenameWithoutExtension(f.path)),
        );
      }
    }
    books.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return books;
  }

  /// Stories, the one played last first.
  Future<List<StorySave>> stories() async {
    final all = await _readAll(
      _stories,
      (dir) => File(p.join(dir, 'story.json')),
      StorySave.fromJson,
      sort: false,
    );
    return all..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
  }

  Future<List<T>> _readAll<T>(
    String folder,
    File Function(String dir) file,
    T Function(Map json) parse, {
    bool sort = true,
  }) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return [];
    final items = <(String, T)>[];
    await for (final d in dir.list()) {
      if (d is! Directory) continue;
      final json = await _readJson(file(d.path));
      if (json == null) continue;
      // The folder is the id, whatever the file says: a copied folder
      // stays a separate item.
      json['id'] = p.basename(d.path);
      final item = parse(json);
      final name = ((json['name'] ?? json['title']) as String?) ?? '';
      // Same names sort by folder, so the list doesn't shuffle.
      items.add(('${name.toLowerCase()}\u0000${p.basename(d.path)}', item));
    }
    if (sort) {
      items.sort((a, b) => a.$1.compareTo(b.$1));
    }
    return [for (final i in items) i.$2];
  }

  static Future<Map<String, Object?>?> _readJson(File f) async {
    try {
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  // Writing. Each save returns the item with its id, a new one taking a
  // free folder name made from its name.

  /// A fresh seed for the colours of something without a picture.
  static int newArt() => Random().nextInt(1 << 31);

  Future<VocesWorld> saveWorld(VocesWorld w) async {
    final id = w.id.isEmpty ? await _freeId(_worlds, w.name) : w.id;
    final saved = w.copyWith(id: id, art: w.art ?? newArt());
    await _writeJson(
      File(p.join(worldFolder(id), 'world.json')),
      saved.toJson(),
    );
    return saved;
  }

  Future<VocesCharacter> saveCharacter(VocesCharacter c) async {
    final id = c.id.isEmpty ? await _freeId(_characters, c.name) : c.id;
    final saved = c.copyWith(id: id, art: c.art ?? newArt());
    await _writeJson(
      File(p.join(characterFolder(id), 'character.json')),
      saved.toJson(),
    );
    return saved;
  }

  Future<Lorebook> saveLorebook(Lorebook b) async {
    final id = b.id.isEmpty
        ? await _freeId(_lorebooks, b.name, suffix: '.json')
        : b.id;
    final saved = b.copyWith(id: id);
    await _writeJson(File(p.join(_lorebooks, '$id.json')), saved.toJson());
    return saved;
  }

  Future<StorySave> saveStory(StorySave s) async {
    await _writeJson(File(p.join(storyFolder(s.id), 'story.json')), s.toJson());
    return s;
  }

  /// Copies [picture] into the item's folder as `picture.<ext>` (or
  /// `portrait.<ext>`) and returns the file name to store.
  Future<String> adoptWorldPicture(String worldId, File picture) =>
      _adopt(worldFolder(worldId), 'picture', picture);
  Future<String> adoptPortrait(String characterId, File picture) =>
      _adopt(characterFolder(characterId), 'portrait', picture);

  Future<void> removeWorldPicture(String worldId) =>
      _drop(worldFolder(worldId), 'picture');
  Future<void> removePortrait(String characterId) =>
      _drop(characterFolder(characterId), 'portrait');

  Future<void> _drop(String folder, String stem) async {
    if (!await Directory(folder).exists()) return;
    await for (final f in Directory(folder).list()) {
      if (f is File && p.basenameWithoutExtension(f.path) == stem) {
        await f.delete();
      }
    }
  }

  /// Where pictures drawn for worlds and characters wait until one is
  /// kept.
  String get drawingFolder => p.join(root, '.drawing');

  Future<String> _adopt(String folder, String stem, File picture) async {
    await Directory(folder).create(recursive: true);
    final ext = p.extension(picture.path).toLowerCase();
    final name = '$stem${ext.isEmpty ? '.png' : ext}';
    // Read first: the new picture may be the old one's own file.
    final bytes = await picture.readAsBytes();
    // Older pictures with another extension would linger otherwise.
    await _drop(folder, stem);
    await File(p.join(folder, name)).writeAsBytes(bytes, flush: true);
    return name;
  }

  // Drafts: an editor left any way but Cancel keeps what was typed here,
  // one file per item (`world-<id>.json`, `world-new.json`…), with a new
  // picture beside it.

  String get draftsFolder => p.join(root, '.drafts');

  /// The key of the draft for a world or character; [id] null for a new
  /// one.
  static String draftKey(String kind, String? id) =>
      '$kind-${id == null || id.isEmpty ? 'new' : id}';

  /// The draft kept under [key], or null.
  VocesDraft? draft(String key) {
    try {
      final f = File(p.join(draftsFolder, '$key.json'));
      if (!f.existsSync()) return null;
      final json = jsonDecode(f.readAsStringSync());
      if (json is! Map<String, Object?> || json['item'] is! Map) return null;
      final picture = json['picture'] as String?;
      return VocesDraft(
        item: (json['item'] as Map).cast<String, Object?>(),
        picture: picture == null ? null : File(picture),
        cleared: json['cleared'] == true,
        saved: DateTime.tryParse(json['saved'] as String? ?? ''),
      );
    } on Object {
      return null;
    }
  }

  /// Keeps a draft under [key]. Written at once (an editor keeps it as it
  /// closes); a drawn [picture] still waiting moves in beside it, so it
  /// outlives the drawing folder. Returns the picture as kept.
  File? keepDraft(
    String key,
    Map<String, Object?> item, {
    File? picture,
    bool cleared = false,
  }) {
    try {
      final dir = Directory(draftsFolder)..createSync(recursive: true);
      // An older picture of this draft goes, unless it's the one kept.
      for (final f in dir.listSync()) {
        if (f is File &&
            p.basename(f.path).startsWith('$key-picture') &&
            !p.equals(f.path, picture?.path ?? '')) {
          f.deleteSync();
        }
      }
      var kept = picture;
      if (picture != null &&
          p.isWithin(drawingFolder, picture.path) &&
          picture.existsSync()) {
        final to = p.join(
          draftsFolder,
          '$key-picture${p.extension(picture.path)}',
        );
        kept = picture.renameSync(to);
      }
      final f = File(p.join(draftsFolder, '$key.json'));
      final tmp = File('${f.path}.tmp')
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'saved': DateTime.now().toIso8601String(),
            'item': item,
            'picture': kept?.path,
            'cleared': cleared,
          }),
        );
      tmp.renameSync(f.path);
      return kept;
    } on Object {
      return picture;
    }
  }

  /// Drops the draft under [key] and any picture kept with it.
  Future<void> dropDraft(String key) async {
    final dir = Directory(draftsFolder);
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      final name = p.basename(f.path);
      if (f is File &&
          (name == '$key.json' || name.startsWith('$key-picture'))) {
        await f.delete();
      }
    }
  }

  /// The keys of every draft kept.
  Future<Set<String>> draftKeys() async {
    final dir = Directory(draftsFolder);
    if (!await dir.exists()) return {};
    final keys = <String>{};
    await for (final f in dir.list()) {
      if (f is File && p.extension(f.path) == '.json') {
        keys.add(p.basenameWithoutExtension(f.path));
      }
    }
    return keys;
  }

  Future<void> deleteWorld(String id) => _deleteDir(worldFolder(id));
  Future<void> deleteCharacter(String id) => _deleteDir(characterFolder(id));
  Future<void> deleteStory(String id) => _deleteDir(storyFolder(id));
  Future<void> deleteLorebook(String id) async {
    final f = File(p.join(_lorebooks, '$id.json'));
    if (await f.exists()) await f.delete();
  }

  Future<void> _deleteDir(String path) async {
    // Only ever inside the library: an empty or odd id must not reach up.
    if (!p.isWithin(root, path)) return;
    final d = Directory(path);
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// Starts a story in [world] with the human playing [player]: the world,
  /// its cast and lorebooks are copied into the story's folder, so later
  /// edits to the world leave this story as it was.
  Future<StorySave> startStory({
    required VocesWorld world,
    required VocesCharacter player,
    required String title,
    Difficulty difficulty = Difficulty.neutral,
    Opening? opening,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final id = await _freeId(_stories, title);
    final folder = storyFolder(id);
    final cast = await characters();
    final books = await lorebooks();
    await _writeJson(File(p.join(folder, 'world.json')), world.toJson());
    for (final c in cast) {
      // The player comes along too: the story needs their sheet.
      if (!world.castIds.contains(c.id) && c.id != player.id) continue;
      await _copyDir(characterFolder(c.id), p.join(folder, 'cast', c.id));
    }
    for (final b in books) {
      if (!world.lorebookIds.contains(b.id)) continue;
      await _writeJson(
        File(p.join(folder, 'lorebooks', '${b.id}.json')),
        b.toJson(),
      );
    }
    final picture = worldPicture(world);
    if (picture != null && await picture.exists()) {
      await picture.copy(p.join(folder, world.picture));
    }
    return saveStory(
      StorySave(
        id: id,
        title: title,
        worldId: world.id,
        worldName: world.name,
        playerId: player.id,
        playerName: player.name,
        difficulty: difficulty,
        opening: opening?.title,
        created: at,
        lastPlayed: at,
      ),
    );
  }

  /// A copy of [story] as a new story called [title]: its world, cast,
  /// lorebooks and pictures as they are now. The turns are copied by the
  /// caller (they live in the story's own encrypted log).
  Future<StorySave> branchStory(
    StorySave story, {
    required String title,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final id = await _freeId(_stories, title);
    await _copyDir(storyFolder(story.id), storyFolder(id));
    return saveStory(
      StorySave(
        id: id,
        title: title,
        worldId: story.worldId,
        worldName: story.worldName,
        playerId: story.playerId,
        playerName: story.playerName,
        difficulty: story.difficulty,
        opening: story.opening,
        created: at,
        lastPlayed: at,
      ).copyWith(place: story.place),
    );
  }

  /// Saves [c] into [story]'s own cast (someone met while playing, or a
  /// sheet changed there); a new one gets a free id in that cast.
  Future<VocesCharacter> saveStoryCharacter(
    StorySave story,
    VocesCharacter c,
  ) async {
    final cast = p.join(storyFolder(story.id), 'cast');
    final id = c.id.isEmpty ? await _freeId(cast, c.name) : c.id;
    final saved = c.copyWith(id: id, art: c.art ?? newArt());
    await _writeJson(File(p.join(cast, id, 'character.json')), saved.toJson());
    return saved;
  }

  /// Copies [c] from [story]'s cast into Characters, portrait and all, as
  /// [name] (their own by default).
  Future<VocesCharacter> copyFromStory(
    StorySave story,
    VocesCharacter c, {
    String? name,
  }) async {
    final named = name ?? c.name;
    final id = await _freeId(_characters, named);
    await _copyDir(
      p.join(storyFolder(story.id), 'cast', c.id),
      characterFolder(id),
    );
    return saveCharacter(c.copyWith(id: id, name: named));
  }

  /// What changed in [story]'s world since the story took its copy: the
  /// world itself, its lorebooks (new, changed, or no longer in it) and its
  /// cast (new or changed; the player stays as they are). Null when the
  /// world is gone.
  Future<WorldUpdate?> worldUpdate(StorySave story) async {
    final world = (await worlds())
        .where((w) => w.id == story.worldId)
        .firstOrNull;
    if (world == null) return null;
    final have = await storyWorld(story);
    String same(Map<String, Object?> json) => jsonEncode(json);
    final books = {for (final b in await lorebooks()) b.id: b};
    final mine = {for (final b in have.lorebooks) b.id: b};
    final cast = {for (final c in await characters()) c.id: c};
    return WorldUpdate(
      world: same(world.toJson()) == same(have.world.toJson()) ? null : world,
      lorebooks: [
        for (final id in world.lorebookIds)
          if (books[id] case final b?)
            if (mine[id] == null)
              (book: b, change: WorldChange.added)
            else if (same(b.toJson()) != same(mine[id]!.toJson()))
              (book: b, change: WorldChange.changed),
        for (final b in have.lorebooks)
          if (!world.lorebookIds.contains(b.id))
            (book: b, change: WorldChange.removed),
      ],
      cast: [
        for (final id in world.castIds)
          if (id != story.playerId)
            if (cast[id] case final c?)
              if (have.cast[id] == null)
                (character: c, change: WorldChange.added)
              else if (same(c.toJson()) != same(have.cast[id]!.toJson()))
                (character: c, change: WorldChange.changed),
      ],
    );
  }

  /// Takes the parts of [update] picked into [story]'s own copy: the world
  /// when [world], and the lorebooks and characters whose ids are given.
  /// The story so far stays as it is.
  Future<StorySave> applyWorldUpdate(
    StorySave story,
    WorldUpdate update, {
    bool world = false,
    Set<String> lorebooks = const {},
    Set<String> cast = const {},
  }) async {
    final folder = storyFolder(story.id);
    var saved = story;
    final w = update.world;
    if (world && w != null) {
      await _writeJson(File(p.join(folder, 'world.json')), w.toJson());
      final picture = worldPicture(w);
      if (picture != null && await picture.exists()) {
        await picture.copy(p.join(folder, w.picture));
      }
      if (w.name != story.worldName) {
        saved = await saveStory(story.copyWith(worldName: w.name));
      }
    }
    for (final (:book, :change) in update.lorebooks) {
      if (!lorebooks.contains(book.id)) continue;
      final f = File(p.join(folder, 'lorebooks', '${book.id}.json'));
      if (change == WorldChange.removed) {
        if (await f.exists()) await f.delete();
      } else {
        await _writeJson(f, book.toJson());
      }
    }
    for (final (:character, change: _) in update.cast) {
      if (!cast.contains(character.id)) continue;
      final to = p.join(folder, 'cast', character.id);
      await _deleteDir(to);
      await _copyDir(characterFolder(character.id), to);
    }
    return saved;
  }

  /// What [story] began with: its own copy of the world, the cast (the
  /// player among them) and the lorebooks.
  Future<StoryWorld> storyWorld(StorySave story) async {
    final folder = storyFolder(story.id);
    final json = await _readJson(File(p.join(folder, 'world.json')));
    final world = json == null
        ? VocesWorld(id: story.worldId, name: story.worldName)
        : VocesWorld.fromJson(json);
    final cast = <String, VocesCharacter>{};
    final castDir = Directory(p.join(folder, 'cast'));
    if (await castDir.exists()) {
      await for (final d in castDir.list()) {
        if (d is! Directory) continue;
        final c = await _readJson(File(p.join(d.path, 'character.json')));
        if (c == null) continue;
        c['id'] = p.basename(d.path);
        cast[p.basename(d.path)] = VocesCharacter.fromJson(c);
      }
    }
    final books = <Lorebook>[];
    final bookDir = Directory(p.join(folder, 'lorebooks'));
    if (await bookDir.exists()) {
      await for (final f in bookDir.list()) {
        if (f is! File || p.extension(f.path) != '.json') continue;
        final b = await _readJson(f);
        if (b != null) books.add(Lorebook.fromJson(b));
      }
    }
    return StoryWorld(
      story: story,
      world: world,
      cast: cast,
      lorebooks: books,
      folder: folder,
    );
  }

  static Future<void> _copyDir(String from, String to) async {
    final src = Directory(from);
    if (!await src.exists()) return;
    await Directory(to).create(recursive: true);
    await for (final e in src.list(recursive: true)) {
      final rel = p.relative(e.path, from: from);
      if (e is Directory) {
        await Directory(p.join(to, rel)).create(recursive: true);
      } else if (e is File) {
        await File(p.join(to, rel)).parent.create(recursive: true);
        await e.copy(p.join(to, rel));
      }
    }
  }

  static Future<void> _writeJson(File f, Map<String, Object?> json) async {
    await f.parent.create(recursive: true);
    // Written beside and renamed, so a crash never leaves half a file.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    await tmp.rename(f.path);
  }

  /// A folder (or file) name made from [name] that isn't taken yet:
  /// "Ember Coast" → `ember-coast`, then `ember-coast-2`…
  Future<String> _freeId(
    String folder,
    String name, {
    String suffix = '',
  }) async {
    final base = slug(name);
    var id = base;
    for (var n = 2; ; n++) {
      final path = p.join(folder, '$id$suffix');
      if (!await File(path).exists() && !await Directory(path).exists()) {
        return id;
      }
      id = '$base-$n';
    }
  }

  /// Lower case letters, digits and dashes, safe on every file system
  /// (letters of any script stay).
  static String slug(String name) {
    final s = name
        .toLowerCase()
        .replaceAll(RegExp(r"['’]"), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final cut = s.length > 40
        ? s.substring(0, 40).replaceAll(RegExp(r'-+$'), '')
        : s;
    return cut.isEmpty ? 'untitled' : cut;
  }
}

/// What an editor was left with: the item as typed, and a new picture or
/// the old one cleared.
class VocesDraft {
  const VocesDraft({
    required this.item,
    this.picture,
    this.cleared = false,
    this.saved,
  });

  final Map<String, Object?> item;
  final File? picture;
  final bool cleared;
  final DateTime? saved;
}

/// A story's own copy of its world, cast and lorebooks.
class StoryWorld {
  const StoryWorld({
    required this.story,
    required this.world,
    required this.cast,
    required this.lorebooks,
    required this.folder,
  });

  final StorySave story;
  final VocesWorld world;

  /// Everyone copied in, by id, the player among them.
  final Map<String, VocesCharacter> cast;
  final List<Lorebook> lorebooks;
  final String folder;

  VocesCharacter? get player => cast[story.playerId];

  /// The world's picture, as copied in.
  File? get picture =>
      world.picture == null ? null : File(p.join(folder, world.picture));

  File? portraitOf(VocesCharacter c) => c.portrait == null
      ? null
      : File(p.join(folder, 'cast', c.id, c.portrait));
}

/// How a part of a world differs from a story's copy of it.
enum WorldChange { added, changed, removed }

/// What changed in a world since a story took its copy; see
/// [VocesLibrary.worldUpdate].
class WorldUpdate {
  const WorldUpdate({
    this.world,
    this.lorebooks = const [],
    this.cast = const [],
  });

  /// The world as it is now, when its setting, rules or anything else of
  /// its own changed.
  final VocesWorld? world;
  final List<({Lorebook book, WorldChange change})> lorebooks;
  final List<({VocesCharacter character, WorldChange change})> cast;

  bool get isEmpty => world == null && lorebooks.isEmpty && cast.isEmpty;
}
