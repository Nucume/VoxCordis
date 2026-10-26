import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_key.dart';

/// Opens the app database and creates the v1 schema.
///
/// Uses the FFI build of sqflite, which works on Linux, macOS and Windows,
/// on SQLite3 Multiple Ciphers: with a [key] (see [DatabaseKey]) everything
/// in the file is encrypted. Pass [inMemoryDatabasePath] as [path] in tests.
Future<Database> openAppDatabase(String path, {String? key}) async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 4,
      onConfigure: (db) async {
        // The key comes first: nothing in the file is readable before it.
        if (key != null) {
          await db.execute('PRAGMA key = ${DatabaseKey.quote(key)}');
        }
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, _) async {
        final batch = db.batch();
        _createV1(batch);
        _upgradeToV2(batch);
        _upgradeToV3(batch);
        _upgradeToV4(batch);
        await batch.commit(noResult: true);
      },
      onUpgrade: (db, from, _) async {
        final batch = db.batch();
        if (from < 2) _upgradeToV2(batch);
        if (from < 3) _upgradeToV3(batch);
        if (from < 4) _upgradeToV4(batch);
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

/// v3: what a shared picture shows, written once by the vision model that
/// looked at it, so later turns can mention it without sending it again.
void _upgradeToV3(Batch b) {
  b.execute('''
    CREATE TABLE picture_notes (
      path        TEXT PRIMARY KEY,
      description TEXT NOT NULL,
      seen_by     TEXT NOT NULL,
      created_at  TEXT NOT NULL
    )''');
}

/// v4: reminders and automations the companion (or the human) set, and a
/// log of each automation run. Times are UTC ISO 8601.
void _upgradeToV4(Batch b) {
  b.execute('''
    CREATE TABLE schedules (
      id           TEXT PRIMARY KEY,
      kind         TEXT NOT NULL,
      text         TEXT NOT NULL,
      next_at      TEXT NOT NULL,
      repeat       TEXT NOT NULL DEFAULT '',
      active       INTEGER NOT NULL DEFAULT 1,
      created_at   TEXT NOT NULL,
      last_run_at  TEXT,
      origin       TEXT NOT NULL DEFAULT 'chat'
    )''');
  b.execute('CREATE INDEX schedules_due ON schedules(active, next_at)');
  b.execute('''
    CREATE TABLE schedule_runs (
      id           TEXT PRIMARY KEY,
      schedule_id  TEXT NOT NULL,
      started_at   TEXT NOT NULL,
      ok           INTEGER NOT NULL,
      summary      TEXT NOT NULL DEFAULT ''
    )''');
  b.execute('CREATE INDEX schedule_runs_started ON schedule_runs(started_at)');
}
