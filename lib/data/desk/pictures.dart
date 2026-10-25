import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// Pictures in the companion's folder: its portrait (`avatar.png`, or .jpg
/// or .webp), which the companion picks itself, and the pictures its human
/// shares in the chat, saved under `images/`. A shared picture shows in the
/// message as a line `[image: images/<file>]`.
class Pictures {
  static const extensions = ['png', 'jpg', 'jpeg', 'webp'];
  static const sharedFolder = 'images';
  static final _marker = RegExp(r'^\[image: ([^\]\n]+)\]$', multiLine: true);

  /// The portrait in [folder], if there is one.
  static File? avatarIn(String folder) {
    for (final ext in extensions) {
      final f = File(p.join(folder, 'avatar.$ext'));
      if (f.existsSync()) return f;
    }
    return null;
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

  /// Copies [source] to `avatar.<ext>` in [folder] and removes any other
  /// portrait, so there is only ever one.
  static Future<File> setAvatar(String folder, File source) async {
    var ext = p.extension(source.path).replaceFirst('.', '').toLowerCase();
    if (ext == 'jpeg') ext = 'jpg';
    final target = File(p.join(folder, 'avatar.$ext'));
    if (!p.equals(p.absolute(source.path), p.absolute(target.path))) {
      await source.copy(target.path);
    }
    for (final e in extensions) {
      final other = File(p.join(folder, 'avatar.$e'));
      if (other.path != target.path && await other.exists()) {
        await other.delete();
      }
    }
    return target;
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
