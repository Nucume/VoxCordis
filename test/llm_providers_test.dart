import 'dart:convert';

import 'package:companion/services/llm_client.dart';
import 'package:companion/services/llm_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('providers are recognised by their address', () {
    expect(
      LlmProvider.forEndpoint('https://openrouter.ai/api/v1'),
      LlmProvider.openRouter,
    );
    expect(
      LlmProvider.forEndpoint('https://api.openai.com/v1/'),
      LlmProvider.openAi,
    );
    expect(
      LlmProvider.forEndpoint('https://API.anthropic.com/v1'),
      LlmProvider.anthropic,
    );
    expect(
      LlmProvider.forEndpoint('http://localhost:11434/v1'),
      LlmProvider.custom,
    );
    expect(LlmProvider.forEndpoint(''), LlmProvider.custom);
  });

  /// The request [send] made, answered with [body].
  Future<http.BaseRequest> sent(
    String baseUrl,
    Future<void> Function(LlmClient c) send, {
    String body = '{"data":[]}',
  }) async {
    late http.BaseRequest seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(body, 200);
    });
    await send(
      LlmClient(baseUrl: baseUrl, model: 'm', apiKey: 'k', client: client),
    );
    return seen;
  }

  test('Anthropic models are listed with its own key header', () async {
    final req = await sent(
      'https://api.anthropic.com/v1',
      (c) => c.listModels(),
    );
    expect(req.url.toString(), 'https://api.anthropic.com/v1/models?limit=100');
    expect(req.headers['x-api-key'], 'k');
    expect(req.headers['anthropic-version'], isNotEmpty);
  });

  test('OpenAI lists only models that can chat', () async {
    final ids = [
      'gpt-4o',
      'gpt-4o-realtime-preview',
      'text-embedding-3-small',
      'dall-e-3',
      'o3-mini',
      'tts-1',
    ];
    late List<String> models;
    await sent(
      'https://api.openai.com/v1',
      (c) async => models = await c.listModels(),
      body: jsonEncode({
        'data': [
          for (final id in ids) {'id': id},
        ],
      }),
    );
    expect(models, ['gpt-4o', 'o3-mini']);
  });

  test('OpenRouter is told which app is asking', () async {
    final req = await sent(
      'https://openrouter.ai/api/v1',
      (c) => c.chat(const []).drain<void>(),
      body: 'data: [DONE]\n\n',
    );
    expect(req.headers['X-Title'], 'VoxCordis');
  });

  test('OpenAI gets max_completion_tokens, others max_tokens', () async {
    Future<Map> body(String url) async {
      final mock = MockClient(
        (req) async => http.Response('data: [DONE]\n\n', 200),
      );
      late Map json;
      final client = _Spy(mock, (b) => json = b);
      await LlmClient(
        baseUrl: url,
        model: 'm',
        maxTokens: 50,
        client: client,
      ).chat(const []).drain<void>();
      return json;
    }

    final openAi = await body('https://api.openai.com/v1');
    expect(openAi['max_completion_tokens'], 50);
    expect(openAi.containsKey('max_tokens'), isFalse);
    final local = await body('http://localhost:11434/v1');
    expect(local['max_tokens'], 50);
  });
}

/// Hands each request body to [onBody] before [inner] answers it.
class _Spy extends http.BaseClient {
  _Spy(this.inner, this.onBody);

  final http.Client inner;
  final void Function(Map body) onBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request) onBody(jsonDecode(request.body) as Map);
    return inner.send(request);
  }
}
