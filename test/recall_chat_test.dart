import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/data/skills/skills.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/logs/app_log.dart';
import 'package:companion/services/recall/recall.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'recall_test.dart' show FakeEmbedder;

/// A fake server that answers every chat request with a short reply.
Future<(HttpServer, List<Map>)> _mockLlm() async {
  final requests = <Map>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    requests.add(jsonDecode(await utf8.decodeStream(req)) as Map);
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.write(
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': 'Sure.'},
          },
        ],
      })}\n\n',
    );
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  return (server, requests);
}

void main() {
  test('the prompt carries moments from older chat found by meaning', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
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
    );
    final embedder = FakeEmbedder();
    services.recall = Recall(
      index: () => services.recallIndex,
      memories: () => services.memory,
      messages: () => services.messages,
      embedder: embedder,
      available: () => true,
      log: services.log,
    );
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });

    // An old exchange, then enough chat to push it out of the recent turns.
    await services.messages.add('user', 'Found a great ramen place in town');
    await services.messages.add('assistant', 'Noodles! Which one?');
    for (var i = 0; i < 25; i++) {
      await services.messages.add('user', 'Just saying hi $i');
      await services.messages.add('assistant', 'Hi back $i');
    }
    await services.memory.remember(text: 'Favourite tea is genmaicha');
    await services.recall.update();

    final chat = ChatController(services);
    await chat.load();
    await chat.send('Any good restaurant to try?');
    expect(chat.error, isNull);

    final system =
        ((requests.single['messages'] as List).first as Map)['content']
            as String;
    expect(system, contains('## Moments from earlier'));
    expect(system, contains('Haru: "Found a great ramen place in town"'));
    expect(system, contains('You: "Noodles! Which one?"'));
    expect(system, contains('Favourite tea is genmaicha')); // pinned
    final logged = await services.log.entries();
    expect(
      logged
          .where((e) => e.kind == LogKind.thinking)
          .map((e) => e.toText())
          .join('\n'),
      contains('Recalled by meaning'),
    );

    // The new exchange is embedded once the reply is in.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      embedder.seen.last,
      startsWith('Any good restaurant to try?\n\nSure.'),
    );
  });

  test('the skill that fits what was said is put in the prompt', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final folder = '${tmp.path}/Aria';
    final services = AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(
          companionName: 'Aria',
          companionFolder: folder,
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'mock',
        ),
      ),
      db: db,
      dbKey: DatabaseKey(Directory.systemTemp),
      runtime: RuntimeController(tmp),
    );
    services.recall = Recall(
      index: () => services.recallIndex,
      memories: () => services.memory,
      messages: () => services.messages,
      embedder: FakeEmbedder(),
      available: () => true,
      log: services.log,
    );
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });
    await Skills.load(folder);
    // The morning briefing mentions the weather too.
    await Skills.setOn(folder, 'morning-briefing', false);

    final chat = ChatController(services);
    await chat.load();
    await chat.send('Do I need an umbrella today?');
    expect(chat.error, isNull);
    String system(int i) =>
        ((requests[i]['messages'] as List).first as Map)['content'] as String;
    expect(system(0), contains('## A skill that fits: Weather'));
    expect(system(0), contains('wttr.in'));
    // The best fit is listed first.
    expect(system(0), contains('On (4 of ${Skills.maxOn}):\n- weather:'));
    final logged = await services.log.entries();
    expect(
      logged.map((e) => e.toText()).join('\n'),
      contains('Offered the Weather skill'),
    );

    await chat.send('My cat says hi');
    expect(system(1), isNot(contains('A skill that fits')));
  });
}
