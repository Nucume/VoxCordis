import 'dart:io';

import 'package:path/path.dart' as p;

/// The temporary folders an import unpacks pictures into: a downloaded
/// portrait, a card's PNG, a Nemini avatar. Setup copies the chosen one
/// into the companion's folder, so none of them is needed afterwards.
class ImportTemp {
  static const _prefix = 'voxcordis-import';

  static Future<Directory> create() => Directory.systemTemp.createTemp(_prefix);

  /// Whether [path] is a file in one of these folders.
  static bool holds(String? path) =>
      path != null &&
      p.isWithin(Directory.systemTemp.path, path) &&
      p.basename(p.dirname(path)).startsWith(_prefix);

  /// Deletes the folder [path] sits in, if it is one of these.
  static Future<void> remove(String? path) async {
    if (!holds(path)) return;
    try {
      await Directory(p.dirname(path!)).delete(recursive: true);
    } on FileSystemException {
      // Already gone, or in use.
    }
  }

  /// Deletes every one of these folders, for the start of the app, when no
  /// import is running. Leftovers come from a setup that was cancelled or a
  /// picture that was replaced. Folders holding one of [keep] stay.
  static Future<void> clearAll({Iterable<String?> keep = const []}) async {
    final kept = {
      for (final k in keep)
        if (holds(k)) p.canonicalize(p.dirname(k!)),
    };
    try {
      await for (final e in Directory.systemTemp.list()) {
        if (e is Directory &&
            p.basename(e.path).startsWith(_prefix) &&
            !kept.contains(p.canonicalize(e.path))) {
          await e.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Nothing to clear, or not ours to clear.
    }
  }
}
