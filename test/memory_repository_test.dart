import 'dart:convert';
import 'dart:io';

import 'package:companion/data/database.dart';
import 'package:companion/data/memory/memory_repository.dart';
import 'package:companion/data/memory/memory_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late MemoryRepository repo;

  setUp(() async {
    db = await openAppDatabase(inMemoryDatabasePath);
    repo = MemoryRepository(db);
  });

  tearDown(() => db.close());

  test('a memory without text is refused, not saved blank', () async {
    final tools = MemoryTools(repo);
    for (final args in [
      <String, Object?>{'fact': 'Likes tea'},
      <String, Object?>{'text': '  '},
      <String, Object?>{'text': '2026-10-24 01:44:31.680515'},
    ]) {
      final r = jsonDecode(await tools.call('remember', args)) as Map;
      expect(r['ok'], false);
      expect(r['error'], contains('"text"'));
    }
    expect(await repo.current(), isEmpty);
  });

  test('remember stores a current fact', () async {
    final m = await repo.remember(
      text: 'Runs InvokeAI locally',
      category: 'project',
      priority: 70,
    );
    final current = await repo.current();
    expect(current.single.id, m.id);
    expect(current.single.isCurrent, isTrue);
  });

  test('update supersedes the old fact and keeps history', () async {
    final old = await repo.remember(text: 'Favourite colour is blue');
    final next = await repo.update(old.id, text: 'Favourite colour is green');

    final current = await repo.current();
    expect(current.map((m) => m.text), ['Favourite colour is green']);

    final history = await repo.history(next.id);
    expect(history.map((m) => m.text), [
      'Favourite colour is green',
      'Favourite colour is blue',
    ]);
    expect(history.last.validTo, isNotNull);
    expect(history.last.supersededBy, next.id);
  });

  test('update refuses a superseded fact', () async {
    final old = await repo.remember(text: 'a');
    await repo.update(old.id, text: 'b');
    expect(() => repo.update(old.id, text: 'c'), throwsStateError);
  });

  test('forget removes the fact and its history', () async {
    final a = await repo.remember(text: 'v1');
    final b = await repo.update(a.id, text: 'v2');
    expect(await repo.forget(b.id), isTrue);
    expect(await db.query('memories'), isEmpty);
  });

  test('the companion\'s forget can be undone for a while', () async {
    final a = await repo.remember(text: 'v1');
    final b = await repo.update(a.id, text: 'v2');
    final now = DateTime.utc(2026, 10, 25);
    expect(await repo.retire(b.id, now: now), isTrue);
    // Out of mind, older versions gone, the fact itself kept.
    expect(await repo.current(), isEmpty);
    expect(await repo.recall('v2'), isEmpty);
    expect((await repo.forgotten()).map((m) => m.text), ['v2']);
    expect(await db.query('memories'), hasLength(1));
    // Only current facts are forgotten.
    expect(await repo.retire(b.id, now: now), isFalse);

    await repo.restore(b.id);
    expect((await repo.current()).map((m) => m.text), ['v2']);
    expect(await repo.forgotten(), isEmpty);

    await repo.retire(b.id, now: now);
    await repo.purgeForgotten(now: now.add(const Duration(days: 29)));
    expect(await repo.forgotten(), hasLength(1));
    await repo.purgeForgotten(now: now.add(const Duration(days: 31)));
    expect(await db.query('memories'), isEmpty);
  });

  test('a v1 database gains the forgotten column', () async {
    final path = '${Directory.systemTemp.createTempSync('db').path}/v1.db';
    sqfliteFfiInit();
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE memories (id TEXT PRIMARY KEY, valid_to TEXT)',
        ),
      ),
    );
    await old.close();
    final upgraded = await openAppDatabase(path);
    final cols = await upgraded.rawQuery('PRAGMA table_info(memories)');
    expect(cols.map((c) => c['name']), contains('forgotten_at'));
    await upgraded.close();
  });

  test('recall returns top priority plus keyword matches', () async {
    await repo.remember(text: 'Name is Nucume', priority: 100);
    await repo.remember(text: 'Likes the Half-Life series', priority: 10);
    await repo.remember(text: 'Owns a cat', priority: 5);

    final recalled = await repo.recall('what about half-life?', pinned: 1);
    expect(recalled.map((m) => m.text), [
      'Name is Nucume',
      'Likes the Half-Life series',
    ]);

    final hit = (await repo.current()).firstWhere(
      (m) => m.text.contains('Half-Life'),
    );
    expect(hit.reinforcedCount, 1);
  });

  test('recall ignores superseded facts', () async {
    final old = await repo.remember(text: 'Lives in Berlin', priority: 90);
    await repo.update(old.id, text: 'Lives in Zurich');
    final recalled = await repo.recall('where does he live');
    expect(recalled.map((m) => m.text), ['Lives in Zurich']);
  });

  test('memory tools run remember, update and forget', () async {
    final tools = MemoryTools(repo);
    final r1 =
        jsonDecode(
              await tools.call('remember', {
                'text': 'Prefers short replies',
                'priority': 60,
              }),
            )
            as Map;
    expect(r1['ok'], isTrue);

    final r2 =
        jsonDecode(
              await tools.call('update_memory', {
                'id': r1['id'],
                'text': 'Prefers very short replies',
              }),
            )
            as Map;
    expect(r2['ok'], isTrue);

    final r3 = jsonDecode(await tools.call('forget', {'id': r2['id']})) as Map;
    expect(r3['ok'], isTrue);
    expect(await repo.current(), isEmpty);
    expect(await repo.forgotten(), hasLength(1));

    final bad =
        jsonDecode(
              await tools.call('update_memory', {'id': 'nope', 'text': 'x'}),
            )
            as Map;
    expect(bad['ok'], isFalse);
  });

  test('setPriority changes a current fact in place', () async {
    final m = await repo.remember(text: 'Likes tea', priority: 40);
    await repo.setPriority(m.id, 100);
    final current = await repo.current();
    expect(current.single.id, m.id);
    expect(current.single.priority, 100);
  });
}
