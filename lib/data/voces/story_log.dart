import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database_key.dart';

/// What a turn of a story is.
enum TurnKind {
  /// The narrator: the world, the scene, people without a sheet.
  narrator,

  /// A character of the cast, in their own voice.
  character,

  /// The human's character says something.
  say,

  /// The human's character does something.
  act,

  /// The human asks the narrator for something ("let a storm roll in").
  ask,

  /// Someone comes or goes; shown as a divider.
  scene;

  bool get byHuman => this == say || this == act || this == ask;

  static TurnKind byName(String? n) =>
      values.where((k) => k.name == n).firstOrNull ?? narrator;
}

/// One turn of a story.
class StoryTurn {
  const StoryTurn({
    required this.id,
    required this.kind,
    required this.text,
    this.speakerId,
    this.speaker = '',
    required this.ts,
  });

  final int id;
  final TurnKind kind;
  final String text;

  /// The character speaking ([TurnKind.character]), or whom a scene turn
  /// is about.
  final String? speakerId;

  /// Their name as it was then.
  final String speaker;
  final DateTime ts;

  StoryTurn copyWith({String? text}) => StoryTurn(
    id: id,
    kind: kind,
    text: text ?? this.text,
    speakerId: speakerId,
    speaker: speaker,
    ts: ts,
  );
}

/// A story's turns and its running state (who is here, where), in its own
/// encrypted database: `<app support>/stories/<id>.db`, with the same key
/// as the companions' chats. The story's folder in the library holds only
/// what the story began with.
class StoryLog {
  StoryLog._(this._db);

  final Database _db;

  static Future<StoryLog> open(String path, {String? key}) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          if (key != null) {
            await db.execute('PRAGMA key = ${DatabaseKey.quote(key)}');
          }
        },
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE turns (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              kind       TEXT NOT NULL,
              speaker_id TEXT,
              speaker    TEXT NOT NULL DEFAULT '',
              text       TEXT NOT NULL,
              ts         TEXT NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE state (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )''');
        },
      ),
    );
    return StoryLog._(db);
  }

  Future<void> close() => _db.close();

  Future<List<StoryTurn>> turns() async => [
    for (final r in await _db.query('turns', orderBy: 'id'))
      StoryTurn(
        id: r['id']! as int,
        kind: TurnKind.byName(r['kind'] as String?),
        speakerId: r['speaker_id'] as String?,
        speaker: (r['speaker'] as String?) ?? '',
        text: (r['text'] as String?) ?? '',
        ts: DateTime.tryParse((r['ts'] as String?) ?? '') ?? DateTime(2000),
      ),
  ];

  Future<StoryTurn> add(
    TurnKind kind,
    String text, {
    String? speakerId,
    String speaker = '',
    DateTime? now,
  }) async {
    final ts = now ?? DateTime.now();
    final id = await _db.insert('turns', {
      'kind': kind.name,
      'speaker_id': speakerId,
      'speaker': speaker,
      'text': text,
      'ts': ts.toIso8601String(),
    });
    return StoryTurn(
      id: id,
      kind: kind,
      text: text,
      speakerId: speakerId,
      speaker: speaker,
      ts: ts,
    );
  }

  Future<void> edit(int id, String text) =>
      _db.update('turns', {'text': text}, where: 'id = ?', whereArgs: [id]);

  /// Drops turn [id] and everything after it.
  Future<void> dropFrom(int id) =>
      _db.delete('turns', where: 'id >= ?', whereArgs: [id]);

  Future<Map<String, Object?>> state() async {
    final out = <String, Object?>{};
    for (final r in await _db.query('state')) {
      try {
        out[r['key']! as String] = jsonDecode(r['value']! as String);
      } on Object {
        // A broken value is left out.
      }
    }
    return out;
  }

  Future<void> setState(String key, Object? value) => _db.insert('state', {
    'key': key,
    'value': jsonEncode(value),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}
