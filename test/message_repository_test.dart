import 'dart:io';

import 'package:companion/data/database.dart';
import 'package:companion/data/message_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  Future<List<String>> plan(Database db, String sql) async => [
    for (final r in await db.rawQuery('EXPLAIN QUERY PLAN $sql'))
      r['detail'] as String,
  ];

  test('the chat is read by sort order through an index', () async {
    final db = await openAppDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    // Opening a chat, adding to it and counting what came after a message
    // all went through the whole history without it.
    for (final sql in [
      'SELECT * FROM messages ORDER BY sort_order DESC LIMIT 200',
      'SELECT coalesce(max(sort_order), 0) + 1 FROM messages',
      'SELECT count(*) FROM messages WHERE sort_order > 5',
    ]) {
      final steps = await plan(db, sql);
      expect(steps.join('; '), contains('messages_sort'), reason: sql);
      expect(steps.join('; '), isNot(contains('TEMP B-TREE')), reason: sql);
    }
    final day = await plan(
      db,
      "SELECT * FROM messages WHERE ts >= 'a' AND ts < 'b' "
      'ORDER BY sort_order',
    );
    expect(day.join('; '), contains('messages_ts'));
  });

  test(
    'a database from before the index gets it, and keeps its chat',
    () async {
      sqfliteFfiInit();
      final dir = Directory.systemTemp.createTempSync('messages_v7');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'companion.db');
      // What version 7 left behind, as far as messages go.
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, ts TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL, via TEXT NOT NULL DEFAULT 'app',
              reasoning TEXT, sort_order INTEGER NOT NULL
            )''');
            await db.execute('CREATE INDEX messages_ts ON messages(ts)');
            for (var i = 1; i <= 3; i++) {
              await db.insert('messages', {
                'id': 'm$i',
                'ts': DateTime.utc(2026, 11, i).toIso8601String(),
                'role': i.isOdd ? 'user' : 'assistant',
                'content': 'message $i',
                'sort_order': i,
              });
            }
          },
        ),
      );
      await old.close();

      final db = await openAppDatabase(path);
      addTearDown(db.close);
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'messages'",
      );
      expect([for (final r in indexes) r['name']], contains('messages_sort'));
      final messages = MessageRepository(db);
      expect(
        [for (final m in await messages.recent()) m.content],
        ['message 1', 'message 2', 'message 3'],
      );
      expect((await messages.add('user', 'message 4')).sortOrder, 4);
    },
  );

  test('a day holds exactly what was said on it, to the edges', () async {
    final db = await openAppDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final messages = MessageRepository(db);
    final day = DateTime(2026, 3, 14);
    final times = {
      'the evening before': DateTime(2026, 3, 13, 23, 59, 59, 999, 999),
      'midnight': DateTime(2026, 3, 14),
      'just after midnight': DateTime(2026, 3, 14, 0, 0, 0, 0, 123),
      'a millisecond in': DateTime(2026, 3, 14, 0, 0, 0, 1),
      'noon': DateTime(2026, 3, 14, 12),
      'last moment': DateTime(2026, 3, 14, 23, 59, 59, 999, 999),
      'next midnight': DateTime(2026, 3, 15),
      'next morning': DateTime(2026, 3, 15, 8, 30),
    };
    var n = 0;
    for (final MapEntry(key: what, value: at) in times.entries) {
      await db.insert('messages', {
        'id': what,
        // As MessageRepository.add and the importers save it.
        'ts': at.toUtc().toIso8601String(),
        'role': 'user',
        'content': what,
        'sort_order': ++n,
      });
    }
    final found = [for (final m in await messages.forDay(day)) m.content];
    expect(found, [
      'midnight',
      'just after midnight',
      'a millisecond in',
      'noon',
      'last moment',
    ]);
    // The same answer as asking SQLite for the local date of each one,
    // which is how the day was found before (and how the list of days
    // still is).
    final byDate = await db.rawQuery(
      "SELECT content FROM messages WHERE date(ts, 'localtime') = ? "
      'ORDER BY sort_order',
      ['2026-03-14'],
    );
    expect(found, [for (final r in byDate) r['content']]);
    expect(await messages.days(), [
      DateTime(2026, 3, 15),
      day,
      DateTime(2026, 3, 13),
    ]);
  });

  test(
    'a day is the same one SQLite would call it, clock changes included',
    () async {
      final db = await openAppDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final messages = MessageRepository(db);
      // Around the days the clocks change in Europe and America (where the
      // machine running this has such a thing), and an ordinary one.
      final batch = db.batch();
      var n = 0;
      for (final start in [
        DateTime.utc(2026, 3, 7),
        DateTime.utc(2026, 3, 28),
        DateTime.utc(2026, 6, 10),
        DateTime.utc(2026, 10, 24),
        DateTime.utc(2026, 10, 31),
      ]) {
        for (
          var t = start;
          t.isBefore(start.add(const Duration(days: 3)));
          t = t.add(const Duration(minutes: 17, milliseconds: 311))
        ) {
          batch.insert('messages', {
            'id': 'm${++n}',
            'ts': t.toIso8601String(),
            'role': 'user',
            'content': 'm$n',
            'sort_order': n,
          });
        }
      }
      await batch.commit(noResult: true);
      final days = await messages.days();
      expect(days.length, greaterThan(14));
      var total = 0;
      for (final day in days) {
        final found = [for (final m in await messages.forDay(day)) m.id];
        final byDate = await db.rawQuery(
          "SELECT id FROM messages WHERE date(ts, 'localtime') = ? "
          'ORDER BY sort_order',
          [day.toIso8601String().substring(0, 10)],
        );
        expect(found, [for (final r in byDate) r['id']], reason: '$day');
        total += found.length;
      }
      expect(total, n);
    },
  );
}
