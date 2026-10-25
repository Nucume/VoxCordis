import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/desk/desk_files.dart';
import '../../data/settings.dart';
import 'imported_character.dart';

/// Writes a reviewed import into the companion folder at the end of setup,
/// before [DeskFiles.ensure] fills in whatever it did not bring.
class ImportWriter {
  /// [body] and [looks] are the human's edited versions. Files already in
  /// the folder (a reinstall into an old folder) are renamed, never
  /// overwritten.
  static Future<({int memories, int messages, int files})> write(
    ImportedCharacter c,
    AppSettings s, {
    required String body,
    required Map<String, String> looks,
    required Database db,
    DateTime? now,
  }) async {
    final folder = s.companionFolder!;
    await Directory(folder).create(recursive: true);
    final stamp = DateFormat('yyyy-MM-dd_HHmmss').format(now ?? DateTime.now());
    Future<void> put(String name, String text) async {
      final f = DeskFiles.fileIn(folder, name);
      if (await f.exists()) {
        final base = p.basenameWithoutExtension(name);
        await f.rename(p.join(folder, '$base.before-import-$stamp.md'));
      }
      await f.writeAsString(text);
    }

    await put(
      DeskFiles.personality,
      DeskFiles.importedPersonality(
        s,
        source: c.source,
        looks: looks,
        body: body,
        rewrite: c.rewrite,
      ),
    );
    if (c.lessons != null && c.lessons!.trim().isNotEmpty) {
      await put(DeskFiles.lessons, '${c.lessons!.trim()}\n');
    }
    if (c.privacy != null && c.privacy!.trim().isNotEmpty) {
      await put(DeskFiles.privacy, '${c.privacy!.trim()}\n');
    }
    return await c.nemini?.apply(db: db, folder: folder) ??
        (memories: 0, messages: 0, files: 0);
  }
}
