import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens the app database and creates the v1 schema.
///
/// Uses the FFI build of sqflite, which works on Linux, macOS and Windows.
/// Pass [inMemoryDatabasePath] as [path] in tests.
Future<Database> openAppDatabase(String path) async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 2,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        final batch = db.batch();
        _createV1(batch);
        _upgradeToV2(batch);
        await batch.commit(noResult: true);
      },
      onUpgrade: (db, from, _) async {
        final batch = db.batch();
        if (from < 2) _upgradeToV2(batch);
        await batch.commit(noResult: true);
      },
    ),
  );
}

void _createV1(Batch b) {
  // Chat history. Columns mirror Nemini's turns.jsonl so the importer can
  // keep its UUIDs and re-imports never duplicate.
  b.execute('''
    CREATE TABLE messages (
      id          TEXT PRIMARY KEY,
      ts          TEXT NOT NULL,
      role        TEXT NOT NULL,
      content     TEXT NOT NULL,
      via         TEXT NOT NULL DEFAULT 'app',
      reasoning   TEXT,
      sort_order  INTEGER NOT NULL
    )''');
  b.execute('CREATE INDEX messages_ts ON messages(ts)');

  // Memory. Mirrors Nemini SmartDisk facts (memory/facts.json).
  // A fact is current while valid_to IS NULL; `update` sets valid_to on the
  // old row and inserts a new one, so history is kept.
  b.execute('''
    CREATE TABLE memories (
      id                TEXT PRIMARY KEY,
      text              TEXT NOT NULL,
      subject           TEXT,
      predicate         TEXT,
      object            TEXT,
      category          TEXT NOT NULL DEFAULT 'general',
      priority          INTEGER NOT NULL DEFAULT 50
                          CHECK (priority BETWEEN 0 AND 100),
      valid_from        TEXT NOT NULL,
      valid_to          TEXT,
      recorded_at       TEXT NOT NULL,
      reinforced_count  INTEGER NOT NULL DEFAULT 0,
      origin            TEXT NOT NULL DEFAULT 'chat',
      folder_path       TEXT,
      source_ids        TEXT NOT NULL DEFAULT '[]',
      superseded_by     TEXT REFERENCES memories(id),
      embedding         BLOB
    )''');
  b.execute('CREATE INDEX memories_current ON memories(valid_to, priority)');
  b.execute('CREATE INDEX memories_subject ON memories(subject)');
}

/// v2: facts the companion forgot are kept a while, restorable, instead of
/// deleted at once.
void _upgradeToV2(Batch b) {
  b.execute('ALTER TABLE memories ADD COLUMN forgotten_at TEXT');
}
