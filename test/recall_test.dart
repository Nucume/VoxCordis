import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion/data/database.dart';
import 'package:companion/data/memory/memory_repository.dart';
import 'package:companion/data/message_repository.dart';
import 'package:companion/data/recall/recall_index.dart';
import 'package:companion/services/recall/embedder.dart';
import 'package:companion/services/recall/recall.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stands in for EmbeddingGemma: every word of a small vocabulary is one
/// direction, synonyms share one, so "kitten" is close to "cat".
class FakeEmbedder implements TextEmbedder {
  static const _dims = {
    'tea': 0,
    'genmaicha': 0,
    'drink': 0,
    'brew': 0,
    'cat': 1,
    'kitten': 1,
    'pet': 1,
    'bike': 2,
    'cycling': 2,
    'ride': 2,
    'ramen': 3,
    'noodles': 3,
    'restaurant': 3,
    'rain': 4,
    'weather': 4,
    'umbrella': 4,
  };

  final seen = <String>[];

  @override
  String get model => 'fake';

  @override
  Future<List<Float32List>> embed(
    List<String> texts, {
    required bool query,
  }) async {
    seen.addAll(texts);
    return [for (final t in texts) vector(t)];
  }

  static Float32List vector(String text) {
    final v = List<double>.filled(8, 0);
    var any = false;
    for (final w in text.toLowerCase().split(RegExp(r'[^a-z]+'))) {
      final d = _dims[w];
      if (d != null) {
        v[d] += 1;
        any = true;
      }
    }
    if (!any) v[7] = 1; // nothing known: a direction of its own
    return RecallIndex.normalize(v);
  }
}

void main() {
  late Database db;
  late RecallIndex index;
  late MemoryRepository memories;
  late MessageRepository messages;
  late FakeEmbedder embedder;
  var available = true;
  late Recall recall;

  setUp(() async {
    db = await openAppDatabase(inMemoryDatabasePath);
    index = RecallIndex(db);
    memories = MemoryRepository(db);
    messages = MessageRepository(db);
    embedder = FakeEmbedder();
    available = true;
    recall = Recall(
      index: () => index,
      memories: () => memories,
      messages: () => messages,
      embedder: embedder,
      available: () => available,
    );
  });

  tearDown(() => db.close());

  test('vectors round-trip and search ranks by cosine', () async {
    final v = RecallIndex.normalize([3, 4, 0]);
    final back = RecallIndex.decode(RecallIndex.encode(v));
    expect(back.length, 3);
    expect(back[0], closeTo(0.6, 1e-6));
    expect(back[1], closeTo(0.8, 1e-6));
    expect(back[2], 0);
    expect(RecallIndex.normalize([0, 0]), [0, 0]);

    final a = await memories.remember(text: 'a');
    final b = await memories.remember(text: 'b');
    final c = await memories.remember(text: 'c');
    await index.putAll(RecallIndex.memoryKind, 'fake', {
      a.id: RecallIndex.normalize([1, 0, 0]),
      b.id: RecallIndex.normalize([1, 1, 0]),
      c.id: RecallIndex.normalize([0, 0, 1]),
    });
    final hits = await index.search(
      RecallIndex.memoryKind,
      'fake',
      RecallIndex.normalize([1, 0, 0]),
      limit: 2,
      minScore: 0.1,
    );
    expect(hits.map((h) => h.id), [a.id, b.id]);
    expect(hits.first.score, closeTo(1, 1e-6));
    // Another model's vectors, and superseded facts, are not searched.
    expect(
      await index.search(
        RecallIndex.memoryKind,
        'other',
        hits.first.id == '' ? Float32List(3) : RecallIndex.normalize([1, 0, 0]),
      ),
      isEmpty,
    );
    await memories.update(a.id, text: 'a2');
    final again = await index.search(
      RecallIndex.memoryKind,
      'fake',
      RecallIndex.normalize([1, 0, 0]),
      minScore: 0.1,
    );
    expect(again.map((h) => h.id), [b.id]);
  });

  test('recall finds memories by meaning and keeps the pinned ones', () async {
    final tea = await memories.remember(
      text: 'Favourite tea is genmaicha',
      priority: 40,
    );
    final cat = await memories.remember(text: 'Has a cat called Momo');
    final top = await memories.remember(text: 'Lives in Bern', priority: 100);
    await recall.update();

    final r = await recall.recall(
      'What should I brew tonight?',
      pinned: 1,
      related: 2,
    );
    expect(r.byMeaning, isTrue);
    expect(r.memories.map((m) => m.id), [top.id, tea.id]);
    expect(r.moments, isEmpty);
    // The one found by meaning counts as reinforced; the pinned one not.
    final now = {for (final m in await memories.current()) m.id: m};
    expect(now[tea.id]!.reinforcedCount, 1);
    expect(now[cat.id]!.reinforcedCount, 0);
    expect(now[top.id]!.reinforcedCount, 0);

    // The query was embedded as a query, the facts as documents.
    expect(embedder.seen, contains('What should I brew tonight?'));
  });

  test('moments from older chat come up; recent turns are left out', () async {
    final noodles = await messages.add('user', 'Found a great ramen place');
    await messages.add('assistant', 'Tell me everything about the noodles!');
    final bike = await messages.add('user', 'Went cycling today');
    await messages.add('assistant', 'How was the ride?');
    final recent = await messages.add('user', 'Rain all day');
    await messages.add('assistant', 'Umbrella weather.');
    await recall.update();

    final r = await recall.recall(
      'Any good restaurant ideas?',
      beforeSortOrder: recent.sortOrder,
    );
    expect(r.moments.length, 1);
    expect(r.moments.single.said.id, noodles.id);
    expect(r.moments.single.reply?.content, contains('noodles'));

    // Only what is before the recent window.
    final r2 = await recall.recall(
      'Rainy weather again',
      beforeSortOrder: recent.sortOrder,
    );
    expect(r2.moments, isEmpty);
    final r3 = await recall.recall('Rainy weather again');
    expect(r3.moments.single.said.id, recent.id);
    expect(bike.id, isNot(r3.moments.single.said.id));
  });

  test('without Recall, words are matched', () async {
    final tea = await memories.remember(text: 'Favourite tea is genmaicha');
    await memories.remember(text: 'Has a cat called Momo');
    available = false;
    await recall.update();
    expect(embedder.seen, isEmpty);
    final r = await recall.recall('genmaicha please', pinned: 0);
    expect(r.byMeaning, isFalse);
    expect(r.memories.map((m) => m.id), [tea.id]);
    expect(r.moments, isEmpty);
  });

  test('update embeds what is new, skips the unanswered message, and '
      'embeds an exchange again on refresh', () async {
    await memories.remember(text: 'Likes tea');
    final asked = await messages.add('user', 'Do you like cats?');
    await recall.update();
    expect(await index.count(RecallIndex.memoryKind, 'fake'), 1);
    // No reply yet: the exchange waits.
    expect(await index.count(RecallIndex.momentKind, 'fake'), 0);

    await messages.add('assistant', 'Kittens most of all.');
    await recall.update(limit: 32, refresh: asked.id);
    expect(await index.count(RecallIndex.momentKind, 'fake'), 1);
    expect(embedder.seen.last, 'Do you like cats?\n\nKittens most of all.');

    // A new reply (regenerate) changes the exchange: refresh embeds it anew.
    await recall.update(refresh: asked.id);
    expect(embedder.seen.where((t) => t.startsWith('Do you like')).length, 2);

    // A pass while one runs is followed by another.
    final first = recall.update();
    final second = recall.update();
    expect(identical(first, second), isTrue);
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(recall.indexing, isFalse);
  });

  test(
    'deleting messages and forgetting memories drops their vectors',
    () async {
      final m = await memories.remember(text: 'Likes tea');
      final a = await messages.add('user', 'Tea?');
      await messages.add('assistant', 'Always.');
      final b = await messages.add('user', 'Cats?');
      await messages.add('assistant', 'Kittens.');
      await recall.update();
      expect(await index.count(RecallIndex.momentKind, 'fake'), 2);

      await messages.delete(a.id);
      expect(await index.count(RecallIndex.momentKind, 'fake'), 1);
      await messages.deleteFrom(b);
      expect(await index.count(RecallIndex.momentKind, 'fake'), 0);
      await memories.forget(m.id);
      expect(await index.count(RecallIndex.memoryKind, 'fake'), 0);

      // A vector whose row went another way is swept at the next pass.
      await index.putAll(RecallIndex.momentKind, 'fake', {
        'gone': RecallIndex.normalize([1]),
      });
      await recall.update();
      expect(await index.count(RecallIndex.momentKind, 'fake'), 0);
    },
  );

  test(
    'the embedder prefixes and cuts texts and reads vectors in order',
    () async {
      expect(
        Embedder.prepare('  Likes   tea ', query: true),
        'task: search result | query: Likes tea',
      );
      expect(
        Embedder.prepare('x' * (Embedder.maxChars + 5), query: false).length,
        Embedder.documentPrefix.length + Embedder.maxChars,
      );

      final requests = <Map>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final body = jsonDecode(await utf8.decodeStream(req)) as Map;
        requests.add(body);
        expect(req.headers.value('authorization'), 'Bearer key');
        final inputs = body['input'] as List;
        req.response.headers.contentType = ContentType.json;
        // Out of order, as a server may answer.
        req.response.write(
          jsonEncode({
            'data': [
              for (var i = inputs.length - 1; i >= 0; i--)
                {
                  'index': i,
                  'embedding': [i + 1.0, 0, 0],
                },
            ],
          }),
        );
        await req.response.close();
      });
      final embedder = Embedder(
        target: () async =>
            (baseUrl: 'http://127.0.0.1:${server.port}/v1', apiKey: 'key'),
      );
      final texts = [for (var i = 0; i < Embedder.batch + 2; i++) 'text $i'];
      final vectors = await embedder.embed(texts, query: false);
      expect(vectors.length, texts.length);
      // Normalised, and matched to their texts by index.
      expect(vectors.first, [1, 0, 0]);
      expect(vectors.last, [1, 0, 0]);
      expect(requests.length, 2);
      expect(
        (requests.first['input'] as List).first,
        '${Embedder.documentPrefix}text 0',
      );
      expect((requests.last['input'] as List).length, 2);
    },
  );

  test('a text the server turns down goes alone, cut shorter', () async {
    final seen = <List<String>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map;
      final inputs = (body['input'] as List).cast<String>();
      seen.add(inputs);
      if (inputs.any((t) => t.length > 1500)) {
        req.response.statusCode = 500;
        req.response.write('{"error":{"message":"input is too large"}}');
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'data': [
              for (var i = 0; i < inputs.length; i++)
                {
                  'index': i,
                  'embedding': [1, 0],
                },
            ],
          }),
        );
      }
      await req.response.close();
    });
    final embedder = Embedder(
      target: () async =>
          (baseUrl: 'http://127.0.0.1:${server.port}/v1', apiKey: ''),
    );
    final long = 'y' * 4000;
    final vectors = await embedder.embed(['short', long, 'tiny'], query: false);
    expect(vectors.length, 3);
    // The batch failed, then each alone; the long one halved until taken.
    expect(seen.first.length, 3);
    expect(seen.where((r) => r.length == 1).length, 5);
    expect(seen.last.single, '${Embedder.documentPrefix}tiny');
  });
}
