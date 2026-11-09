import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:companion/services/model_calls.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;

/// A fake server that answers every request with [reply].
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

String _delta(String text) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': text},
          'finish_reason': null,
        },
      ],
    })}\n\n';

/// Writes [first] of a long answer, then drops the connection, the way a
/// crashing llama-server does.
Future<void> _drop(HttpResponse res, String first) async {
  res.contentLength = 1 << 20;
  final socket = await res.detachSocket();
  socket.write(_delta(first));
  await socket.flush();
  socket.destroy();
}

Future<void> _say(HttpResponse res, String text) async {
  res.write(_delta(text));
  await res.close();
}

Future<(ModelCalls, RuntimeController)> _calls(
  HttpServer server, {
  double? temperature,
}) async {
  final tmp = await Directory.systemTemp.createTemp('companion_test');
  addTearDown(() => tmp.delete(recursive: true));
  final runtime = RuntimeController(tmp);
  final s = AppSettings(
    llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
    llmMode: LlmMode.external,
    llmModel: 'mock',
    temperature: temperature,
  );
  return (ModelCalls(runtime: runtime, settings: () => s), runtime);
}

void main() {
  test('a client carries the settings, with extras on top', () {
    const s = AppSettings(
      llmMode: LlmMode.external,
      llmModel: 'mock',
      temperature: 0.9,
    );
    const target = (baseUrl: 'http://x/v1', model: 'mock', apiKey: 'k');
    final plain = chatClient(target, s);
    expect(plain.model, 'mock');
    expect(plain.apiKey, 'k');
    expect(plain.sampling, {'temperature': 0.9});
    expect(plain.stop, isEmpty);
    final more = chatClient(
      target,
      s,
      sampling: const {'temperature': 0.2},
      stop: const ['\nHaru:'],
      maxTokens: 50,
    );
    expect(more.sampling, {'temperature': 0.2});
    expect(more.stop, ['\nHaru:']);
    expect(more.maxTokens, 50);
  });

  test('ask gives the answer and lets the model go again', () async {
    final (server, requests) = await _server((res) => _say(res, 'Blue.'));
    final (calls, runtime) = await _calls(server);
    expect(await calls.ask('Be brief.', 'Sky?', maxTokens: 10), 'Blue.');
    expect(requests.single['messages'], [
      {'role': 'system', 'content': 'Be brief.'},
      {'role': 'user', 'content': 'Sky?'},
    ]);
    // Room for a model that thinks anyway.
    expect(requests.single['max_tokens'], 4010);
    expect(runtime.busy, isFalse);
  });

  test('an exact ask keeps the temperature low', () async {
    final (server, requests) = await _server((res) => _say(res, 'ok'));
    final (hot, _) = await _calls(server, temperature: 1.1);
    await hot.ask('s', 'u', exact: true);
    expect(requests.last['temperature'], 0.3);
    final (cool, _) = await _calls(server, temperature: 0.1);
    await cool.ask('s', 'u', exact: true);
    expect(requests.last['temperature'], 0.1);
    await hot.ask('s', 'u');
    expect(requests.last['temperature'], 1.1);
  });

  test('ask tries once more when the connection drops', () async {
    var n = 0;
    final (server, requests) = await _server(
      (res) => n++ == 0 ? _drop(res, 'Half a') : _say(res, 'A whole answer.'),
    );
    final (calls, runtime) = await _calls(server);
    expect(await calls.ask('s', 'u'), 'A whole answer.');
    expect(requests, hasLength(2));
    expect(runtime.busy, isFalse);
  });

  test('ask gives up when the connection keeps dropping', () async {
    final (server, requests) = await _server((res) => _drop(res, 'Half'));
    final (calls, runtime) = await _calls(server);
    await expectLater(calls.ask('s', 'u'), throwsA(isA<ClientException>()));
    expect(requests, hasLength(2));
    expect(runtime.busy, isFalse);
  });

  test('a stream cut short is written again from its start', () async {
    var n = 0;
    final (server, requests) = await _server(
      (res) => n++ == 0 ? _drop(res, 'The door cr') : _say(res, 'The door.'),
    );
    final (calls, runtime) = await _calls(server);
    final text = StringBuffer();
    var restarts = 0;
    await for (final piece in calls.stream(
      's',
      'u',
      stop: const ['\nHaru:'],
      again: () {
        restarts++;
        text.clear();
      },
    )) {
      text.write(piece);
    }
    expect(text.toString(), 'The door.');
    expect(restarts, 1);
    expect(requests, hasLength(2));
    expect(requests.last['stop'], ['\nHaru:']);
    expect(runtime.busy, isFalse);
  });

  test('a stream that keeps dropping ends in an error', () async {
    final (server, requests) = await _server((res) => _drop(res, 'Half'));
    final (calls, runtime) = await _calls(server);
    var restarts = 0;
    await expectLater(
      calls.stream('s', 'u', again: () => restarts++).drain<void>(),
      throwsA(isA<ClientException>()),
    );
    expect(restarts, 1);
    expect(requests, hasLength(2));
    expect(runtime.busy, isFalse);
  });

  test('a stream nobody can restart is not asked twice', () async {
    final (server, requests) = await _server((res) => _drop(res, 'Half'));
    final (calls, runtime) = await _calls(server);
    final text = StringBuffer();
    await expectLater(
      calls.stream('s', 'u').forEach(text.write),
      throwsA(isA<ClientException>()),
    );
    expect(text.toString(), 'Half');
    expect(requests, hasLength(1));
    expect(runtime.busy, isFalse);
  });

  test('a stream nobody listens to any more is not written again', () async {
    final (server, requests) = await _server((res) => _drop(res, 'Half'));
    final (calls, runtime) = await _calls(server);
    var restarts = 0;
    late final StreamSubscription<String> sub;
    final got = Completer<String>();
    sub = calls.stream('s', 'u', again: () => restarts++).listen((piece) {
      got.complete(piece);
      sub.cancel();
    });
    expect(await got.future, 'Half');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(restarts, 0);
    expect(requests, hasLength(1));
    expect(runtime.busy, isFalse);
  });

  test(
    'withChatModel holds the model for the body and lets go after',
    () async {
      final tmp = await Directory.systemTemp.createTemp('companion_test');
      addTearDown(() => tmp.delete(recursive: true));
      final runtime = RuntimeController(tmp);
      const s = AppSettings(
        llmEndpoint: 'http://x/v1',
        llmMode: LlmMode.external,
        llmModel: 'mock',
      );
      final model = await withChatModel(runtime, () => s, (target) async {
        expect(runtime.busy, isTrue);
        return target.model;
      });
      expect(model, 'mock');
      expect(runtime.busy, isFalse);
      await expectLater(
        withChatModel<void>(runtime, () => s, (_) => throw StateError('no')),
        throwsStateError,
      );
      expect(runtime.busy, isFalse);
    },
  );
}
