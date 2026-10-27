import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/message_repository.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/data/story_repository.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/story/story_keeper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fake server: a request about the running summary gets "Summary N"
/// (N counting up), any other one "Sure.". [slow] holds every answer
/// until it completes.
Future<(HttpServer, List<Map>)> _mockLlm({Completer<void>? slow}) async {
  final requests = <Map>[];
  var summaries = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = jsonDecode(await utf8.decodeStream(req)) as Map;
    requests.add(body);
    if (slow != null) await slow.future;
    final system = ((body['messages'] as List).first as Map)['content'];
    final text = '$system'.contains('running summary')
        ? 'Summary ${++summaries}'
        : 'Sure.';
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.write(
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      })}\n\n',
    );
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  return (server, requests);
}

ChatMessage _m(int n) => ChatMessage(
  id: '$n',
  ts: DateTime(2026),
  role: n.isOdd ? 'user' : 'assistant',
  content: 'm$n',
  sortOrder: n,
);

Future<AppServices> _services(HttpServer server, Directory tmp, Database db) {
  return Future.value(
    AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(
          companionName: 'Aria',
          userName: 'Haru',
          companionFolder: '${tmp.path}/Aria',
          modelsFolder: '${tmp.path}/models',
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'mock',
        ),
      ),
      db: db,
      dbKey: DatabaseKey(Directory.systemTemp),
      runtime: RuntimeController(tmp),
    ),
  );
}

void main() {
  test('the recent window and what to fold', () {
    final all = [for (var n = 1; n <= 30; n++) _m(n)];
    // No story yet: the last 18 are recent, the 16 before them get folded.
    expect(StoryKeeper.recent(all, null).map((m) => m.sortOrder).first, 13);
    expect(StoryKeeper.recent(all, null).length, StoryKeeper.maxWindow);
    final fold = StoryKeeper.toFold(all, null).map((m) => m.sortOrder);
    expect(fold.first, 3);
    expect(fold.last, 18);
    // Up to date: the window is what is after the story.
    expect(StoryKeeper.recent(all, 18).map((m) => m.sortOrder).first, 19);
    expect(StoryKeeper.toFold(all, 18), isEmpty);
    // Past the most: everything but the last twelve goes.
    final more = [
      ...all,
      _m(31),
      _m(32),
      _m(33),
      _m(34),
      _m(35),
      _m(36),
      _m(37),
    ];
    expect(StoryKeeper.recent(more, 18).length, 18);
    expect(StoryKeeper.toFold(more, 18).map((m) => m.sortOrder), [
      19,
      20,
      21,
      22,
      23,
      24,
      25,
    ]);
  });

  test('the story is kept per companion and dropped by a rewind', () async {
    final db = await openAppDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final story = StoryRepository(db);
    final messages = MessageRepository(db);
    expect(await story.get(), isNull);
    final a = await messages.add('user', 'a');
    final b = await messages.add('assistant', 'b');
    final c = await messages.add('user', 'c');
    await story.set('They said a and b.', through: b.sortOrder);
    expect((await story.get())!.text, 'They said a and b.');
    await story.set('Newer.', through: b.sortOrder);
    expect((await story.get())!.text, 'Newer.');
    // Deleting after the story keeps it; rewinding into it drops it.
    await messages.deleteFrom(c);
    expect((await story.get())!.through, b.sortOrder);
    await messages.deleteFrom(b);
    expect(await story.get(), isNull);
    expect((await messages.recent()).map((m) => m.id), [a.id]);
    await story.set('x', through: 1);
    await story.clear();
    expect(await story.get(), isNull);
  });

  test('catchUp folds aged-out messages into the story', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('story');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = await _services(server, tmp, db);
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });
    final sent = <ChatMessage>[];
    for (var n = 1; n <= 20; n++) {
      sent.add(
        await services.messages.add(n.isOdd ? 'user' : 'assistant', 'm$n'),
      );
    }
    final keeper = services.storyKeeper;
    await keeper.catchUp();
    var story = await services.story.get();
    expect(story!.text, 'Summary 1');
    expect(story.through, sent[7].sortOrder); // m1..m8 folded, 12 remain
    final first = requests.single['messages'] as List;
    expect((first.first as Map)['content'], contains('between Haru and Aria'));
    final asked = (first.last as Map)['content'] as String;
    expect(asked, contains('(The chat has just begun.)'));
    expect(asked, contains('Haru: m1'));
    expect(asked, contains('Aria: m8'));
    expect(asked, isNot(contains('m9')));
    // A tool-free request at low temperature.
    expect(requests.single.containsKey('tools'), isFalse);
    expect(requests.single['temperature'], 0.3);

    // Nothing more to fold until the window is past its most.
    await keeper.catchUp();
    expect(requests.length, 1);
    for (var n = 21; n <= 27; n++) {
      sent.add(
        await services.messages.add(n.isOdd ? 'user' : 'assistant', 'm$n'),
      );
    }
    await keeper.catchUp();
    story = await services.story.get();
    expect(story!.text, 'Summary 2');
    expect(story.through, sent[14].sortOrder); // m9..m15
    final second = (requests.last['messages'] as List).last as Map;
    expect(second['content'], contains('Summary so far:\nSummary 1'));
    expect(second['content'], contains('Haru: m9'));
    expect(second['content'], contains('Haru: m15'));
    expect(second['content'], isNot(contains('m16')));

    // Only one update at a time.
    final x = keeper.catchUp();
    expect(identical(x, keeper.catchUp()), isTrue);
    await x;
  });

  test('cancel stops an update and keeps the story as it was', () async {
    final slow = Completer<void>();
    final (server, requests) = await _mockLlm(slow: slow);
    final tmp = await Directory.systemTemp.createTemp('story');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = await _services(server, tmp, db);
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });
    for (var n = 1; n <= 20; n++) {
      await services.messages.add(n.isOdd ? 'user' : 'assistant', 'm$n');
    }
    final keeper = services.storyKeeper;
    final running = keeper.catchUp();
    while (requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(keeper.busy, isTrue);
    keeper.cancel();
    await running;
    slow.complete();
    expect(keeper.busy, isFalse);
    expect(await services.story.get(), isNull);
    expect(services.runtime.busy, isFalse);
  });

  test('the prompt carries the story and only the recent messages', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('story');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = await _services(server, tmp, db);
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });
    for (var n = 1; n <= 40; n++) {
      await services.messages.add(n.isOdd ? 'user' : 'assistant', 'm$n');
    }
    final chat = ChatController(services);
    await chat.load();
    await chat.send('m41');
    expect(chat.error, isNull);
    // No story yet: the last 18 messages (m24..m41) went; the window
    // starts on the human, so m24, a reply, is left off.
    var sentMessages = requests.first['messages'] as List;
    var system = (sentMessages.first as Map)['content'] as String;
    expect(system, isNot(contains('The story so far')));
    expect(sentMessages.length, 1 + 17);
    expect((sentMessages[1] as Map)['content'], 'm25');
    // After the reply (m42), the 16 messages before the last 12 were
    // folded in: m15..m30.
    while (services.storyKeeper.busy || requests.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final story = await services.story.get();
    expect(story!.text, 'Summary 1');
    expect(story.through, 30);
    final folded = ((requests[1]['messages'] as List).last as Map)['content'];
    expect(folded, contains('Haru: m15'));
    expect(folded, contains('Aria: m30'));
    expect(folded, isNot(contains('m31')));

    // From now on: the story, and the messages after it.
    await chat.send('m43');
    sentMessages = requests.last['messages'] as List;
    system = (sentMessages.first as Map)['content'] as String;
    expect(system, contains('## The story so far'));
    expect(system, contains('Summary 1'));
    expect((sentMessages[1] as Map)['content'], 'm31');
    expect(sentMessages.length, 1 + 13);
  });
}
