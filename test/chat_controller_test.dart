import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/system/installed_apps.dart';
import 'package:companion/services/system/system_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fake OpenAI-compatible server: the first request gets a streamed
/// `remember` tool call, every later one a streamed text reply.
Future<(HttpServer, List<Map>)> _mockLlm() async {
  final requests = <Map>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = jsonDecode(await utf8.decodeStream(req)) as Map;
    requests.add(body);
    req.response.headers.contentType = ContentType('text', 'event-stream');
    void send(Map delta) => req.response.write(
      'data: ${jsonEncode({
        'choices': [
          {'delta': delta},
        ],
      })}\n\n',
    );
    if (requests.length == 1) {
      send({'reasoning_content': 'They told me a favourite. '});
      send({'reasoning_content': 'I should remember it.'});
      send({
        'tool_calls': [
          {
            'index': 0,
            'id': 'c1',
            'function': {
              'name': 'remember',
              'arguments': '{"text": "Favourite tea ',
            },
          },
        ],
      });
      send({
        'tool_calls': [
          {
            'index': 0,
            'function': {'arguments': 'is genmaicha", "priority": 60}'},
          },
        ],
      });
    } else {
      for (final w in ['Noted, ', 'genmaicha ', 'it is.']) {
        send({'content': w});
      }
    }
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  return (server, requests);
}

void main() {
  test('send streams a reply, runs memory tools and recalls them', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(
          companionName: 'Aria',
          companionFolder: '${tmp.path}/Aria',
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'mock',
        ),
      ),
      db: db,
      runtime: RuntimeController(tmp),
    );
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });

    final chat = ChatController(services);
    await chat.send('Remember my favourite tea is genmaicha');

    expect(chat.error, isNull);
    expect(chat.messages.map((m) => m.role), ['user', 'assistant']);
    expect(chat.messages.last.content, 'Noted, genmaicha it is.');
    // The note says what was saved.
    expect(chat.toolNote, 'Remembered: "Favourite tea is genmaicha"');
    // The reasoning is kept with the reply, apart from its text, and is
    // never sent back to the model as history.
    expect(
      chat.messages.last.reasoning,
      'They told me a favourite. I should remember it.',
    );
    expect(
      (await services.messages.recent()).last.reasoning,
      'They told me a favourite. I should remember it.',
    );

    final memories = await services.memory.current();
    expect(memories.single.text, 'Favourite tea is genmaicha');
    expect(memories.single.sourceIds, [chat.messages.first.id]);

    // The core file was written and sent as the system prompt, with tools.
    final first = requests.first;
    final system = (first['messages'] as List).first as Map;
    expect(system['content'], startsWith('# You are Aria'));
    expect(system['content'], contains('# Aria'));
    // An external server keeps its own sampler settings.
    expect(first.containsKey('temperature'), isFalse);
    // personality.md and lessons.md ride along on every turn.
    expect(system['content'], contains('title: Personality'));
    expect(system['content'], contains('# Lessons'));
    expect(
      [for (final t in first['tools'] as List) t['function']['name']],
      containsAll([
        'remember',
        'update_memory',
        'forget',
        'read_file',
        'edit_file',
        'write_file',
        'learn_lesson',
        'set_avatar',
      ]),
    );
    // The second round carries the tool result back to the model.
    final second = requests[1]['messages'] as List;
    expect((second.last as Map)['role'], 'tool');
    // With an id Mistral's template accepts (nine letters and digits), the
    // same on the call and on its result.
    final callId =
        (((second[second.length - 2] as Map)['tool_calls'] as List).single
            as Map)['id'];
    expect(callId, matches(RegExp(r'^[A-Za-z0-9]{9}$')));
    expect((second.last as Map)['tool_call_id'], callId);
    // Nobody set a name for the human yet, so the companion is told to ask.
    expect(system['content'], contains("haven't set a name"));

    // Next turn, the app recalls the fact without the model asking.
    await chat.send('What tea should I make?');
    final recalledPrompt =
        ((requests.last['messages'] as List).first as Map)['content'] as String;
    expect(recalledPrompt, contains('Favourite tea is genmaicha'));

    // History is persisted.
    expect((await services.messages.recent()).length, 4);

    // A shared picture is copied into the folder and named in the message,
    // and the prompt tells the companion it can't see it but may use it.
    final picture = await File(
      '${tmp.path}/selfie.png',
    ).writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
    await chat.send('', images: [picture.path]);
    final shared = chat.messages[chat.messages.length - 2];
    expect(
      shared.content,
      matches(RegExp(r'^\[image: images/.+-selfie\.png\]$')),
    );
    final rel = RegExp(r'images/[^\]]+').firstMatch(shared.content)![0]!;
    expect(File('${tmp.path}/Aria/$rel').existsSync(), isTrue);
    final pictureSystem =
        ((requests.last['messages'] as List).first as Map)['content'] as String;
    expect(pictureSystem, contains('You cannot see pictures yet'));
    expect(pictureSystem, contains('set_avatar'));
  });

  test(
    'regenerate replaces the last reply; delete removes a message',
    () async {
      final (server, requests) = await _mockLlm();
      final tmp = await Directory.systemTemp.createTemp('companion_test');
      final db = await openAppDatabase(inMemoryDatabasePath);
      final services = AppServices(
        settings: SettingsStore(
          File('${tmp.path}/settings.json'),
          AppSettings(
            companionFolder: '${tmp.path}/c',
            llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
            llmMode: LlmMode.external,
            llmModel: 'mock',
          ),
        ),
        db: db,
        runtime: RuntimeController(tmp),
      );
      addTearDown(() async {
        await server.close(force: true);
        await db.close();
        await tmp.delete(recursive: true);
      });

      final chat = ChatController(services);
      await chat.send('hi'); // first mock answer is a tool call, then text
      final firstReply = chat.messages.last;
      expect(firstReply.role, 'assistant');

      await chat.regenerate();
      expect(chat.messages.map((m) => m.role), ['user', 'assistant']);
      expect(chat.messages.last.id, isNot(firstReply.id));
      expect(chat.messages.last.content, 'Noted, genmaicha it is.');
      // The regenerated request ends with the same user turn, not a duplicate.
      final last = requests.last['messages'] as List;
      expect(last.where((m) => (m as Map)['role'] == 'user').length, 1);

      await chat.delete(chat.messages.first);
      expect(chat.messages.map((m) => m.role), ['assistant']);
      expect((await services.messages.recent()).length, 1);

      // Today's messages show up in the day list and in showDay.
      expect(chat.days, hasLength(1));
      await chat.showDay(DateTime.now());
      expect(chat.viewingDay, isNull); // today is the live view
      expect(await services.messages.forDay(DateTime.now()), hasLength(1));
    },
  );

  test('Stop keeps what was written and offers Retry', () async {
    // A server that writes a little, then keeps the reply open.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await utf8.decodeStream(req);
      req.response.bufferOutput = false;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Let me think about '},
            },
          ],
        })}\n\n',
      );
      await req.response.flush();
      await Future<void>.delayed(const Duration(seconds: 30));
      await req.response.close();
    });
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(
          companionFolder: '${tmp.path}/c',
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'mock',
        ),
      ),
      db: db,
      runtime: RuntimeController(tmp),
    );
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });

    final chat = ChatController(services);
    final sending = chat.send('Tell me everything');
    while (chat.messages.length < 2 || chat.messages.last.content.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    chat.stop();
    await sending.timeout(const Duration(seconds: 5));

    expect(chat.error, isNull);
    expect(chat.stopped, isTrue);
    expect(chat.toolNote, 'Stopped');
    expect(chat.canRetry, isTrue);
    expect(chat.messages.last.content, 'Let me think about ');
    expect(
      (await services.messages.recent()).last.content,
      'Let me think about ',
    );
  });

  test('deleteFrom removes the message and everything after it', () async {
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(companionFolder: '${tmp.path}/c'),
      ),
      db: db,
      runtime: RuntimeController(tmp),
    );
    addTearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    for (final (role, text) in [
      ('user', 'one'),
      ('assistant', 'two'),
      ('user', 'three'),
      ('assistant', 'four'),
    ]) {
      await services.messages.add(role, text);
    }
    final chat = ChatController(services);
    await chat.load();
    final second = chat.messages[1];

    expect(await chat.countAfter(chat.messages.last), 0);
    expect(await chat.countAfter(second), 2);
    // The last reply takes the message it answered with it; others don't.
    expect(chat.questionFor(chat.messages.last)?.content, 'three');
    expect(chat.questionFor(second), isNull);
    expect(chat.questionFor(chat.messages[2]), isNull);

    await chat.deleteFrom(second);
    expect(chat.messages.map((m) => m.content), ['one']);
    expect((await services.messages.recent()).map((m) => m.content), ['one']);

    // Deleting only one message keeps the ones after it.
    await services.messages.add('assistant', 'five');
    await services.messages.add('user', 'six');
    await chat.load();
    await chat.delete(chat.messages[1]);
    expect((await services.messages.recent()).map((m) => m.content), [
      'one',
      'six',
    ]);
  });

  test('a plain "open my Pictures folder" is put to the human', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(
          companionFolder: '${tmp.path}/c',
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'mock',
          systemAccess: true,
        ),
      ),
      db: db,
      runtime: RuntimeController(tmp),
    );
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });
    final asked = <SystemRequest>[];
    services.systemTools.ask = (r) async {
      asked.add(r);
      return SystemApproval.deny;
    };

    final chat = ChatController(services);
    await chat.send('Want to try open my File Explorer to my Pictures folder?');

    expect(asked.single.target, 'Pictures');
    expect(asked.single.why, contains('You asked'));
    // The model hears how it went before it writes a word.
    final sent = requests.first['messages'] as List;
    final call = sent[sent.length - 2] as Map;
    expect((call['tool_calls'] as List).single['function']['name'], 'open');
    expect((sent.last as Map)['content'], contains('said no'));
  });
  test('"open Vivaldi please" starts the app after asking', () async {
    final (server, requests) = await _mockLlm();
    final tmp = await Directory.systemTemp.createTemp('companion_test');
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File('${tmp.path}/settings.json'),
        AppSettings(
          companionFolder: '${tmp.path}/c',
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'mock',
          systemAccess: true,
        ),
      ),
      db: db,
      runtime: RuntimeController(tmp),
    );
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await tmp.delete(recursive: true);
    });
    final asked = <SystemRequest>[];
    services.systemTools.apps = InstalledApps(
      list: () async => const [
        InstalledApp(name: 'Vivaldi', id: 'vivaldi-stable.desktop'),
      ],
    );
    services.systemTools.ask = (r) async {
      asked.add(r);
      return SystemApproval.deny;
    };

    final chat = ChatController(services);
    await chat.send('Open Vivaldi please');

    expect(asked.single.target, 'Vivaldi');
    expect(asked.single.why, contains('You asked'));
    // The model hears how it went before it writes a word.
    final sent = requests.first['messages'] as List;
    final call = sent[sent.length - 2] as Map;
    expect((call['tool_calls'] as List).single['function']['name'], 'open');
    expect((sent.last as Map)['content'], contains('said no'));
  });
}
