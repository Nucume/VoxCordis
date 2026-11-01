import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// Pictures in the companion's folder: its portrait (`avatar.png`, or .jpg
/// or .webp), which the companion picks itself, and the pictures its human
/// shares in the chat, saved under `images/`. A shared picture shows in the
/// message as a line `[image: images/<file>]`.
///
/// An imported portrait can come as a set: a video (`avatar.mp4`) that
/// plays over the still, and an 18+ version of both (`avatar-nsfw.png`,
/// `avatar-nsfw.mp4`) shown instead when the human chose so.
class Pictures {
  static const extensions = ['png', 'jpg', 'jpeg', 'webp'];

  /// A video portrait (`avatar.mp4`), which plays over the still one.
  static const videoExtensions = ['mp4', 'webm'];
  static const sharedFolder = 'images';
  static final _marker = RegExp(r'^\[image: ([^\]\n]+)\]$', multiLine: true);

  /// Every file of a portrait set: `avatar.png`, `avatar-nsfw.mp4`…
  static final _avatarFile = RegExp(
    r'^avatar(-nsfw)?\.(png|jpe?g|webp|mp4|webm)$',
  );

  /// The portrait in [folder], if there is one; with [nsfw], its 18+
  /// version when it has one.
  static File? avatarIn(String folder, {bool nsfw = false}) {
    final main = _still(folder, 'avatar');
    if (!nsfw || main == null) return main;
    return _still(folder, 'avatar-nsfw') ?? main;
  }

  static File? _still(String folder, String stem) {
    for (final ext in extensions) {
      final f = File(p.join(folder, '$stem.$ext'));
      if (f.existsSync()) return f;
    }
    return null;
  }

  /// Whether the portrait at [still] has an 18+ version beside it.
  static bool hasNsfwBeside(String? still) =>
      still != null && _still(p.dirname(still), 'avatar-nsfw') != null;

  /// The clip that goes with the still portrait at [still] (`avatar.png`
  /// or `avatar-nsfw.png`): the `.mp4` or `.webm` of the same name.
  static File? avatarVideoBeside(String? still) {
    if (still == null) return null;
    final stem = p.basenameWithoutExtension(still);
    if (stem != 'avatar' && stem != 'avatar-nsfw') return null;
    for (final ext in videoExtensions) {
      final f = File(p.join(p.dirname(still), '$stem.$ext'));
      if (f.existsSync()) return f;
    }
    return null;
  }

  static final _background = RegExp(r'^background-\d+\.(png|jpe?g|webp)$');

  /// The picture behind the app for the companion in [folder], if it has
  /// one. Each new one gets a new name, so a cached old one never shows.
  static File? backgroundIn(String folder) {
    final dir = Directory(folder);
    if (!dir.existsSync()) return null;
    for (final e in dir.listSync()) {
      if (e is File && _background.hasMatch(p.basename(e.path))) return e;
    }
    return null;
  }

  /// Copies [source] into [folder] as the background picture, replacing
  /// the last one.
  static Future<File> setBackground(String folder, File source) async {
    var ext = p.extension(source.path).replaceFirst('.', '').toLowerCase();
    if (ext == 'jpeg') ext = 'jpg';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = File(p.join(folder, 'background-$stamp.$ext'));
    await source.copy(target.path);
    await _dropBackgrounds(folder, keep: target.path);
    return target;
  }

  static Future<void> clearBackground(String folder) =>
      _dropBackgrounds(folder);

  static Future<void> _dropBackgrounds(String folder, {String? keep}) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File &&
          e.path != keep &&
          _background.hasMatch(p.basename(e.path))) {
        await e.delete();
      }
    }
  }

  static bool hasImageExtension(String path) => extensions.contains(
    p.extension(path).replaceFirst('.', '').toLowerCase(),
  );

  /// Whether [file] starts like a PNG, JPEG or WebP image.
  static Future<bool> isImage(File file) async {
    final head = <int>[];
    await for (final chunk in file.openRead(0, 12)) {
      head.addAll(chunk);
    }
    return imageExtensionOf(head) != null;
  }

  /// 'png', 'jpg' or 'webp' when [head] starts like one, else null.
  static String? imageExtensionOf(List<int> head) {
    bool at(int i, List<int> bytes) {
      if (head.length < i + bytes.length) return false;
      for (var j = 0; j < bytes.length; j++) {
        if (head[i + j] != bytes[j]) return false;
      }
      return true;
    }

    if (at(0, [0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (at(0, [0xFF, 0xD8, 0xFF])) return 'jpg';
    if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
    return null;
  }

  /// Copies [source] to `avatar.<ext>` in [folder] and removes every
  /// other portrait file, so there is only ever one. A video portrait and
  /// an 18+ version go too, since they belong to the old picture.
  static Future<File> setAvatar(String folder, File source) async {
    var ext = p.extension(source.path).replaceFirst('.', '').toLowerCase();
    if (ext == 'jpeg') ext = 'jpg';
    final target = File(p.join(folder, 'avatar.$ext'));
    if (!p.equals(p.absolute(source.path), p.absolute(target.path))) {
      await source.copy(target.path);
    }
    await _dropAvatarFiles(folder, keep: {target.path});
    return target;
  }

  /// Copies the portrait [still] and the rest of its set beside it (its
  /// video, the 18+ still and video) into [folder], replacing the old set.
  static Future<File> setAvatarSet(String folder, File still) async {
    final from = p.dirname(still.path);
    final kept = <String>{};
    for (final e in Directory(from).listSync()) {
      final name = p.basename(e.path);
      if (e is! File || !_avatarFile.hasMatch(name)) continue;
      final target = p.join(folder, name.replaceFirst('.jpeg', '.jpg'));
      if (!p.equals(p.absolute(e.path), p.absolute(target))) {
        await e.copy(target);
      }
      kept.add(target);
    }
    await _dropAvatarFiles(folder, keep: kept);
    return avatarIn(folder)!;
  }

  static Future<void> _dropAvatarFiles(
    String folder, {
    required Set<String> keep,
  }) async {
    for (final e in Directory(folder).listSync()) {
      if (e is File &&
          _avatarFile.hasMatch(p.basename(e.path)) &&
          !keep.any((k) => p.equals(k, e.path))) {
        await e.delete();
      }
    }
  }

  /// Copies a picture the human shares into `images/` and returns its path
  /// relative to [folder], always with forward slashes.
  static Future<String> share(
    String folder,
    String source,
    DateTime now,
  ) async {
    final dir = Directory(p.join(folder, sharedFolder));
    await dir.create(recursive: true);
    final stamp = DateFormat('yyyy-MM-dd_HHmmss').format(now);
    final base = p.basenameWithoutExtension(source);
    final ext = p.extension(source).toLowerCase();
    var name = '$stamp-$base$ext';
    for (var n = 2; await File(p.join(dir.path, name)).exists(); n++) {
      name = '$stamp-$base-$n$ext';
    }
    await File(source).copy(p.join(dir.path, name));
    return '$sharedFolder/$name';
  }

  static String marker(String relative) => '[image: $relative]';

  /// The shared pictures named in a message, relative to the folder.
  static List<String> inText(String text) => [
    for (final m in _marker.allMatches(text)) m.group(1)!.trim(),
  ];

  /// The message without its picture lines.
  static String withoutMarkers(String text) =>
      text.replaceAll(_marker, '').trim();

  /// The shared picture [relative] names, or null when that is not a
  /// picture inside [folder]. Message text can come from the model, so a
  /// marker must not reach other files: clicking a picture opens it with the
  /// system's default app, which would run a script or program.
  static File? fileIn(String folder, String relative) {
    if (!hasImageExtension(relative)) return null;
    final root = p.normalize(p.absolute(folder));
    final full = p.normalize(p.joinAll([root, ...relative.split('/')]));
    return p.isWithin(root, full) ? File(full) : null;
  }
}
