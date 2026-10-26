import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Descriptions of the pictures shared in the chat, by their path in the
/// companion folder (`images/...`). Kept in the companion's database, so
/// they are encrypted with the chat.
class PictureNotes {
  PictureNotes(this._db);

  final Database _db;

  Future<String?> get(String path) async {
    final rows = await _db.query(
      'picture_notes',
      columns: ['description'],
      where: 'path = ?',
      whereArgs: [path],
    );
    return rows.isEmpty ? null : rows.single['description'] as String;
  }

  /// [description] of the picture at [path], written by [seenBy] (the
  /// model's name).
  Future<void> put(String path, String description, {required String seenBy}) =>
      _db.insert('picture_notes', {
        'path': path,
        'description': description,
        'seen_by': seenBy,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
}
