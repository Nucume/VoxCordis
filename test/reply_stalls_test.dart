import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/features/chat/prompt_history.dart';
import 'package:companion/services/llm_client.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fake server that answers every request with [reply]: it gets the open
/// response and writes what it likes, then may leave it hanging.
Future<(HttpServer, List<Map>)> _server(
  Future<void> Function(HttpResponse res) reply,
) async {
  final requests = <Map>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    requests.add(jsonDecode(await utf8.decodeStream(req)) as Map);
    req.response
      ..headers.contentType = ContentType('text', 'event-stream')
      ..bufferOutput = false;
    await reply(req.response);
  });
  addTearDown(() => server.close(force: true));
  return (server, requests);
}

String _chunk(Map<String, Object?> json) => 'data: ${jsonEncode(json)}\n\n';

String _delta(Map<String, Object?> delta, {String? finish}) => _chunk({
  'choices': [
    {'delta': delta, 'finish_reason': finish},
  ],
});

LlmClient _client(HttpServer s, {Duration? first, Duration? next}) => LlmClient(
  baseUrl: 'http://127.0.0.1:${s.port}/v1',
  model: 'mock',
  maxTokens: 100,
  progress: true,
  firstWait: first,
  stallWait: next,
);

Future<ChatController> _chat(HttpServer server) async {
  final tmp = await Directory.systemTemp.createTemp('companion_test');
  final db = await openAppDatabase(inMemoryDatabasePath);
  addTearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });
  return ChatController(
    AppServices(
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
    ),
  );
}

void main() {
  test('a server that goes quiet mid-reply fails instead of hanging', () async {
    final (server, requests) = await _server((res) async {
      res.write(_delta({'content': 'Hello '}));
      await res.flush();
      // …and nothing more, connection left open.
    });
    final text = StringBuffer();
    final run = () async {
      await for (final e in _client(
        server,
        first: const Duration(seconds: 2),
        next: const Duration(milliseconds: 300),
      ).chat([])) {
        if (e is TextDelta) text.write(e.text);
      }
    }();
    await expectLater(run, throwsA(isA<LlmStalled>()));
    expect(text.toString(), 'Hello ');
    // The request asks for a cap and for progress while reading.
    expect(requests.single['max_tokens'], 100);
    expect(requests.single['return_progress'], true);
  });

  test('a server that never starts fails after the first wait', () async {
    final (server, _) = await _server((res) async {
      // Headers never sent.
      await Completer<void>().future;
    });
    final run = _client(
      server,
      first: const Duration(milliseconds: 300),
    ).chat([]).toList();
    await expectLater(run, throwsA(isA<LlmStalled>()));
  });

  test('an error sent inside the stream is reported', () async {
    final (server, _) = await _server((res) async {
      res.write(_delta({'content': 'Hi'}));
      res.write(
        _chunk({
          'error': {'message': 'the request exceeds the context size'},
        }),
      );
      await res.close();
    });
    await expectLater(
      _client(server).chat([]).toList(),
      throwsA(
        isA<LlmException>().having(
          (e) => e.message,
          'message',
          contains('context size'),
        ),
      ),
    );
  });

  test('prompt progress and the finish reason come through', () async {
    final (server, _) = await _server((res) async {
      for (final done in [100, 550, 1000]) {
        res.write(
          _chunk({
            'choices': [
              {
                'delta': {'role': 'assistant', 'content': null},
              },
            ],
            'prompt_progress': {'total': 1000, 'cache': 100, 'processed': done},
          }),
        );
      }
      res.write(_delta({'content': 'Hi'}, finish: 'length'));
      await res.close();
    });
    final client = _client(server);
    final events = await client.chat([]).toList();
    expect(
      [
        for (final e in events)
          if (e is PromptProgress) e.fraction,
      ],
      [0, 0.5, 1],
    );
    expect(client.finishReason, 'length');
  });

  group('loopCut', () {
    test('finds a passage repeated over and over and keeps one copy', () {
      const start = 'I think about what they said. ';
      const loop = 'Maybe I should ask them how the day went. ';
      final text = start + loop * 8;
      final kept = text.substring(0, loopCut(text));
      expect(kept, startsWith(start));
      expect('Maybe'.allMatches(kept).length, 1);
      expect(kept.trimRight(), endsWith('went'));
    });

    test('leaves ordinary text and short repeats alone', () {
      expect(loopCut('*giggles* ' * 20), isNull); // too short a passage
      expect(loopCut('Hello there. ' * 2), isNull);
      expect(
        loopCut(
          'She smiles and leans closer. "Tell me everything," she says, '
          'tapping the table. The rain keeps on outside.',
        ),
        isNull,
      );
    });
  });

  test('a reply that thinks in circles is cut short with a retry', () async {
    final (server, _) = await _server((res) async {
      res.write(_delta({'reasoning_content': 'Let me think. '}));
      for (var i = 0; i < 40; i++) {
        res.write(
          _delta({'reasoning_content': 'Wait, what did they mean by that? '}),
        );
      }
      await res.flush();
      // A looping model would go on until its context is full.
      await Completer<void>().future;
    });
    final chat = await _chat(server);
    await chat.send('hi');
    expect(chat.error, contains('going round in circles'));
    expect(chat.canRetry, isTrue);
    // The empty reply is gone rather than shown as typing forever.
    expect(chat.messages.map((m) => m.role), ['user']);
  });

  test('a looping reply keeps one copy and says it was cut', () async {
    final (server, _) = await _server((res) async {
      res.write(_delta({'content': '*smiles* Hi! '}));
      for (var i = 0; i < 40; i++) {
        res.write(_delta({'content': 'I missed you so much today. '}));
      }
      await res.close();
    });
    final chat = await _chat(server);
    await chat.send('hi');
    expect(chat.error, isNull);
    expect(
      chat.messages.last.content,
      '*smiles* Hi! I missed you so much today.',
    );
    expect(chat.toolNote, contains('repeating itself'));
  });

  test('an empty reply is an error, not a bubble typing forever', () async {
    final (server, _) = await _server((res) async {
      res.write(_delta({'content': '<tool_call>not json</tool_call>'}));
      res.write('data: [DONE]\n\n');
      await res.close();
    });
    final chat = await _chat(server);
    await chat.send('hi');
    expect(chat.error, contains("didn't write anything"));
    expect(chat.messages.map((m) => m.role), ['user']);
  });

  test('a written-out end mark ends the reply there', () async {
    final (server, _) = await _server((res) async {
      for (final w in [
        '*waves* Hi',
        ' there!<|im',
        '_end|im_end|>\nUser: ',
        'more',
      ]) {
        res.write(_delta({'content': w}));
      }
      await res.close();
    });
    final chat = await _chat(server);
    await chat.send('hi');
    expect(chat.error, isNull);
    expect(chat.messages.last.content, '*waves* Hi there!');
  });
}
