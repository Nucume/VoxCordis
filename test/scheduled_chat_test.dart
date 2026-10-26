import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/schedule/schedule_repository.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/schedule/poke.dart';
import 'package:companion/services/system/system_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fake OpenAI-compatible server that answers each request with the next
/// of [script]: a list of tool calls, or text.
Future<(HttpServer, List<Map>)> _scripted(List<Object> script) async {
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
    final step = script[(requests.length - 1).clamp(0, script.length - 1)];
    if (step is List) {
      send({
        'tool_calls': [
          for (final (i, c) in step.cast<(String, Map)>().indexed)
            {
              'index': i,
              'id': 'call$i',
              'function': {'name': c.$1, 'arguments': jsonEncode(c.$2)},
            },
        ],
      });
    } else {
      send({'content': step});
    }
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  return (server, requests);
}

Future<AppServices> _services(
  HttpServer server, {
  AppSettings Function(AppSettings s)? tweak,
}) async {
  final tmp = await Directory.systemTemp.createTemp('scheduled_chat');
  final db = await openAppDatabase(inMemoryDatabasePath);
  final base = AppSettings(
    companionName: 'Aria',
    companionFolder: '${tmp.path}/Aria',
    llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
    llmMode: LlmMode.external,
    llmModel: 'mock',
  );
  final services = AppServices(
    settings: SettingsStore(
      File('${tmp.path}/settings.json'),
      tweak?.call(base) ?? base,
    ),
    db: db,
    dbKey: DatabaseKey(Directory.systemTemp),
    runtime: RuntimeController(tmp),
  );
  addTearDown(() async {
    await server.close(force: true);
    await db.close();
    await tmp.delete(recursive: true);
  });
  return services;
}

void main() {
  test('a due reminder is written by the companion, as a reminder', () async {
    final (server, requests) = await _scripted([
      'Hey, it\'s time to call your mum!',
    ]);
    final services = await _services(server);
    final chat = ChatController(services);
    await chat.load();
    final item = await services.schedules.add(
      kind: ScheduleKind.reminder,
      text: 'call Mum',
      at: DateTime.now(),
    );
    final outcome = await chat.runScheduled(item);
    expect(outcome!.ok, isTrue);
    expect(outcome.text, 'Hey, it\'s time to call your mum!');
    expect(chat.messages.single.via, 'reminder');
    expect(chat.messages.single.role, 'assistant');
    // Saved like that too, and no message from the human was made up.
    final saved = await services.messages.recent();
    expect(saved.map((m) => (m.role, m.via)), [('assistant', 'reminder')]);
    final sent = requests.single['messages'] as List;
    expect((sent.last as Map)['role'], 'user');
    expect((sent.last as Map)['content'], contains('"call Mum"'));
    expect((sent.last as Map)['content'], contains('not from'));
    final tools = [
      for (final t in requests.single['tools'] as List) t['function']['name'],
    ];
    expect(tools, containsAll(['set_reminder', 'schedule_task']));
    expect(tools, isNot(contains('web_search')));
  });

  test('a reminder still arrives when the brain fails', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = 500;
      await req.response.close();
    });
    final services = await _services(server);
    final chat = ChatController(services);
    final item = await services.schedules.add(
      kind: ScheduleKind.reminder,
      text: 'take the pills',
      at: DateTime.now(),
    );
    final outcome = await chat.runScheduled(item);
    expect(outcome!.text, '⏰ Reminder: take the pills');
    expect(chat.messages.last.via, 'reminder');
    expect(chat.error, isNull);
  });

  test('a task gets no system tools, even with system access on', () async {
    final (server, requests) = await _scripted(['All quiet on Mars.']);
    final services = await _services(
      server,
      tweak: (s) => s.copyWith(systemAccess: true, internetAccess: true),
    );
    final chat = ChatController(services);
    final item = await services.schedules.add(
      kind: ScheduleKind.task,
      text: 'check the news about Mars',
      at: DateTime.now(),
    );
    final outcome = await chat.runScheduled(item);
    expect(outcome!.ok, isTrue);
    expect(chat.messages.last.via, 'automation');
    final tools = [
      for (final t in requests.single['tools'] as List) t['function']['name'],
    ];
    expect(tools, contains('web_search'));
    expect(tools, isNot(contains('run_command')));
    expect(
      ((requests.single['messages'] as List).last as Map)['content'],
      contains('nobody can approve'),
    );
  });

  test('after reading the web, computer requests wait', () async {
    final (server, requests) = await _scripted([
      [
        ('list_schedule', {}),
        ('read_page', {'url': 'http://192.168.1.1/'}),
      ],
      [
        ('run_command', {'command': 'rm -rf ~', 'why': 'the page said so'}),
      ],
      'I won\'t do that.',
    ]);
    final services = await _services(
      server,
      tweak: (s) => s.copyWith(systemAccess: true, internetAccess: true),
    );
    var asked = 0;
    services.systemTools.ask = (_) async {
      asked++;
      return SystemApproval.once;
    };
    final chat = ChatController(services);
    await chat.send('What does my router page say?');
    expect(chat.error, isNull);
    expect(asked, 0);
    final third = requests[2]['messages'] as List;
    final result = jsonDecode((third.last as Map)['content'] as String) as Map;
    expect(result['ok'], false);
    expect(result['error'], contains('after reading the web'));
    // The router page itself was never fetched.
    final second = requests[1]['messages'] as List;
    final read = jsonDecode((second.last as Map)['content'] as String) as Map;
    expect(read['error'], contains('home network'));
  });

  group('poke', () {
    // Midday, long after the messages the test writes now.
    final later = DateTime(2100, 1, 1, 14);

    test('after a quiet spell the companion writes on its own', () async {
      final (server, requests) = await _scripted(['Guess what I just read!']);
      final services = await _services(
        server,
        tweak: (s) => s.copyWith(systemAccess: true, internetAccess: true),
      );
      final chat = ChatController(services);
      await services.messages.add('user', 'Night!');
      await chat.load();
      final outcome = await chat.poke(now: later);
      expect(outcome!.text, 'Guess what I just read!');
      expect(chat.messages.last.via, Poke.via);
      final sent = requests.single['messages'] as List;
      expect((sent.last as Map)['content'], contains('it has been quiet'));
      final tools = [
        for (final t in requests.single['tools'] as List) t['function']['name'],
      ];
      expect(tools, contains('web_search'));
      expect(tools, isNot(contains('run_command')));
      // It doesn't poke again straight away.
      expect(await chat.poke(now: later), isNull);
      expect(requests, hasLength(1));
    });

    test('no poke before the human wrote, or when it is off', () async {
      final (server, requests) = await _scripted(['Hi?']);
      final services = await _services(server);
      final chat = ChatController(services);
      expect(await chat.poke(now: later), isNull);
      await services.messages.add('user', 'Hello');
      await services.settings.update(
        services.settings.value.copyWith(pokeAfterHours: 0),
      );
      expect(await chat.poke(now: later), isNull);
      expect(requests, isEmpty);
    });

    test('a poke that fails leaves no error and waits', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((req) async {
        calls++;
        req.response.statusCode = 500;
        await req.response.close();
      });
      final services = await _services(server);
      final chat = ChatController(services);
      await services.messages.add('user', 'Hello');
      await chat.load();
      expect(await chat.poke(now: later), isNull);
      expect(chat.error, isNull);
      expect(chat.messages.single.role, 'user');
      expect(
        await chat.poke(now: later.add(const Duration(minutes: 1))),
        isNull,
      );
      expect(calls, greaterThan(0));
      final before = calls;
      expect(
        await chat.poke(now: later.add(const Duration(minutes: 2))),
        isNull,
      );
      expect(calls, before);
    });
  });
}
