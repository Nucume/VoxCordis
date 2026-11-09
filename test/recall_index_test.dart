import 'dart:math';
import 'dart:typed_data';

import 'package:companion/data/database.dart';
import 'package:companion/data/memory/memory_repository.dart';
import 'package:companion/data/message_repository.dart';
import 'package:companion/data/recall/recall_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Searches the old way, reading every vector from the table, to compare.
Future<List<Hit>> fromTheTable(
  Database db,
  String kind,
  String model,
  Float32List query, {
  int limit = 8,
  double minScore = 0,
}) async {
  final rows = await db.rawQuery(
    kind == RecallIndex.memoryKind
        ? 'SELECT v.id, v.vector FROM vectors v '
              'JOIN memories m ON m.id = v.id '
              'WHERE v.kind = ? AND v.model = ? AND m.valid_to IS NULL'
        : 'SELECT v.id, v.vector FROM vectors v '
              'JOIN messages m ON m.id = v.id '
              'WHERE v.kind = ? AND v.model = ?',
    [kind, model],
  );
  final hits = <Hit>[];
  for (final r in rows) {
    final v = RecallIndex.decode(r['vector'] as Uint8List);
    if (v.length != query.length) continue;
    final score = RecallIndex.dot(query, v);
    if (score >= minScore) hits.add((id: r['id'] as String, score: score));
  }
  hits.sort((a, b) => b.score.compareTo(a.score));
  return hits.length > limit ? hits.sublist(0, limit) : hits;
}

void main() {
  late Database db;
  late RecallIndex index;
  late MemoryRepository memories;
  late MessageRepository messages;
  const memory = RecallIndex.memoryKind, moment = RecallIndex.momentKind;

  setUp(() async {
    db = await openAppDatabase(inMemoryDatabasePath);
    index = RecallIndex(db);
    memories = MemoryRepository(db);
    messages = MessageRepository(db);
  });
  tearDown(() => db.close());

  Float32List unit(List<num> v) => RecallIndex.normalize(v);
  final east = unit([1, 0, 0]);

  Future<List<String>> found(String kind, {String model = 'm'}) async => [
    for (final h in await index.search(kind, model, east, minScore: 0.1)) h.id,
  ];

  test('vectors are read once, then kept up as they come and go', () async {
    final a = await messages.add('user', 'a');
    final b = await messages.add('user', 'b');
    await index.putAll(moment, 'm', {
      a.id: unit([1, 0, 0]),
    });
    expect(index.heldCount(moment), isNull);
    expect(await found(moment), [a.id]);
    expect(index.heldCount(moment), 1);

    // A new one, and a changed one, show without the table being read.
    await index.putAll(moment, 'm', {
      b.id: unit([1, 1, 0]),
    });
    expect(index.heldCount(moment), 2);
    expect(await found(moment), [a.id, b.id]);
    await index.putAll(moment, 'm', {
      a.id: unit([0, 0, 1]),
    });
    expect(index.heldCount(moment), 2);
    expect(await found(moment), [b.id]);

    await index.remove(moment, [b.id]);
    expect(index.heldCount(moment), 1);
    expect(await found(moment), isEmpty);
    // What the table holds is what a fresh index finds too.
    expect(
      await RecallIndex(db).search(moment, 'm', unit([0, 0, 1])),
      hasLength(1),
    );
  });

  test('a vector deleted with its message is no longer found', () async {
    final a = await messages.add('user', 'a');
    final b = await messages.add('user', 'b');
    final c = await messages.add('user', 'c');
    await index.putAll(moment, 'm', {
      a.id: unit([1, 0, 0]),
      b.id: unit([1, 0.1, 0]),
      c.id: unit([1, 0.2, 0]),
    });
    expect(await found(moment), [a.id, b.id, c.id]);
    // MessageRepository deletes the vector row itself.
    await messages.delete(a.id);
    expect(await found(moment), [b.id, c.id]);
    expect(index.heldCount(moment), 2);
    await messages.deleteFrom(b);
    expect(await found(moment), isEmpty);
    expect(index.heldCount(moment), 0);
  });

  test(
    'a message gone without its vector is not found, and is swept',
    () async {
      final a = await messages.add('user', 'a');
      final b = await messages.add('user', 'b');
      await index.putAll(moment, 'm', {
        a.id: unit([1, 0, 0]),
        b.id: unit([1, 0.1, 0]),
      });
      expect(await found(moment), [a.id, b.id]);
      await db.delete('messages', where: 'id = ?', whereArgs: [a.id]);
      expect(await found(moment), [b.id]);
      await index.sweep();
      expect(await found(moment), [b.id]);
      expect(index.heldCount(moment), 1);
    },
  );

  test('replaced facts never crowd out current ones', () async {
    // Forty facts that fit perfectly, all replaced since, and five that
    // fit a little less and still stand: the five are what comes back.
    final vectors = <String, Float32List>{};
    for (var i = 0; i < 40; i++) {
      final old = await memories.remember(text: 'old $i');
      vectors[old.id] = unit([1, 0, 0]);
      await memories.update(old.id, text: 'new $i');
    }
    final current = <String>[];
    for (var i = 0; i < 5; i++) {
      final m = await memories.remember(text: 'current $i');
      vectors[m.id] = unit([1, 0.1 + i / 10, 0]);
      current.add(m.id);
    }
    await index.putAll(memory, 'm', vectors);
    expect(await found(memory), current);
    expect([
      for (final h in await fromTheTable(db, memory, 'm', east)) h.id,
    ], current);
  });

  test('another model starts afresh, and takes over row by row', () async {
    final a = await messages.add('user', 'a');
    final b = await messages.add('user', 'b');
    await index.putAll(moment, 'old', {
      a.id: unit([1, 0, 0]),
      b.id: unit([1, 0, 0]),
    });
    expect(await found(moment, model: 'old'), hasLength(2));
    expect(await found(moment, model: 'new'), isEmpty);
    // The new model's vectors are longer, and replace the old one by one.
    final longer = unit([1, 0, 0, 0, 0]);
    await index.putAll(moment, 'new', {a.id: longer});
    expect(
      [for (final h in await index.search(moment, 'new', longer)) h.id],
      [a.id],
    );
    expect(await found(moment, model: 'old'), [b.id]);
    await index.putAll(moment, 'new', {b.id: longer});
    expect(await index.search(moment, 'new', longer), hasLength(2));
    expect(await found(moment, model: 'old'), isEmpty);
  });

  test('thousands of vectors give what reading the table gives', () async {
    final random = Random(7);
    Float32List any() =>
        unit([for (var i = 0; i < 16; i++) random.nextDouble() - 0.5]);
    final batch = db.batch();
    final vectors = <String, Float32List>{};
    for (var i = 1; i <= 5000; i++) {
      batch.insert('messages', {
        'id': 'u$i',
        'ts': DateTime.utc(
          2026,
          1,
          1,
        ).add(Duration(minutes: i)).toIso8601String(),
        'role': 'user',
        'content': 'message $i',
        'sort_order': i,
      });
      vectors['u$i'] = any();
    }
    await batch.commit(noResult: true);
    await index.putAll(moment, 'm', vectors);
    final query = any();
    Future<void> same({double minScore = 0, int limit = 8}) async {
      final held = await index.search(
        moment,
        'm',
        query,
        limit: limit,
        minScore: minScore,
      );
      final table = await fromTheTable(
        db,
        moment,
        'm',
        query,
        limit: limit,
        minScore: minScore,
      );
      expect([for (final h in held) h.id], [for (final h in table) h.id]);
      expect([for (final h in held) h.score], [for (final h in table) h.score]);
    }

    await same();
    await same(minScore: 0.45, limit: 12);
    expect(index.heldCount(moment), 5000);

    // Vectors coming and going while a search is under way (it lets the
    // window breathe every couple of thousand) never give a wrong answer.
    final during = index.search(moment, 'm', query, limit: 5);
    await index.remove(moment, ['u1', 'u2500', 'u5000']);
    await index.putAll(moment, 'm', {'u7': query});
    final hits = await during;
    expect(hits, hasLength(5));
    await same(limit: 5);
    expect((await index.search(moment, 'm', query, limit: 1)).single.id, 'u7');
    expect(index.heldCount(moment), 4997);
  });
}
