import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The story so far: what the chat was about before the recent messages.
class Story {
  const Story({
    required this.text,
    required this.through,
    required this.updatedAt,
  });

  final String text;

  /// Sort order of the last message folded in. Messages after it are in
  /// the prompt as they are.
  final int through;
  final DateTime updatedAt;
}

/// Reads and writes the one-row `story` table.
class StoryRepository {
  StoryRepository(this._db);

  final Database _db;

  Future<Story?> get() async {
    final rows = await _db.query('story', where: 'id = 1');
    if (rows.isEmpty) return null;
    final r = rows.single;
    return Story(
      text: r['text'] as String,
      through: r['through'] as int,
      updatedAt: DateTime.parse(r['updated_at'] as String),
    );
  }

  Future<void> set(String text, {required int through}) => _db.insert('story', {
    'id': 1,
    'text': text,
    'through': through,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> clear() => _db.delete('story');
}
