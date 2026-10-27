import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_providers.dart';

/// A tool call the model asked for, assembled from streamed deltas.
class ToolCall {
  ToolCall(this.id, this.name, this.arguments);
  final String id;
  final String name;
  final String arguments;

  Map<String, Object?> get parsedArguments {
    try {
      return (jsonDecode(arguments.isEmpty ? '{}' : arguments) as Map)
          .cast<String, Object?>();
    } on FormatException {
      return const {};
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

sealed class LlmEvent {}

class TextDelta extends LlmEvent {
  TextDelta(this.text);
  final String text;
}

/// The model's private reasoning, streamed before (or between) its reply.
class ReasoningDelta extends LlmEvent {
  ReasoningDelta(this.text);
  final String text;
}

/// How far the server is through reading the prompt, from 0 to 1, before
/// the first word. Only llama-server sends this, when asked.
class PromptProgress extends LlmEvent {
  PromptProgress(this.fraction);
  final double fraction;
}

class ToolCallsRequested extends LlmEvent {
  ToolCallsRequested(this.calls);
  final List<ToolCall> calls;
}

/// Talks to any OpenAI-compatible `/chat/completions` endpoint (Ollama,
/// LM Studio, llama.cpp, KoboldCpp…) with streaming.
class LlmClient {
  LlmClient({
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.sampling = const {},
    this.stop = const [],
    this.maxTokens,
    this.progress = false,
    this.firstWait,
    this.stallWait,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final String model;
  final String apiKey;

  /// Extra sampler fields for each completion, e.g. temperature.
  final Map<String, num> sampling;

  /// Text that ends a reply, for templates whose end mark the model's
  /// tokenizer doesn't know as one (ChatML on a Mistral finetune).
  final List<String> stop;

  /// Most tokens one completion may write, reasoning included, so a model
  /// stuck in a loop ends instead of running until the context is full.
  final int? maxTokens;

  /// Ask llama-server to report its progress through the prompt. That also
  /// keeps the stream alive while a long prompt is read.
  final bool progress;

  /// How long to wait for the server's first sign of life, and then between
  /// chunks, before giving up with [LlmStalled]. Null waits forever.
  final Duration? firstWait;
  final Duration? stallWait;

  /// Why the last completion ended: "stop", "length", "tool_calls"…
  String? finishReason;

  final http.Client _http;

  Uri _url(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  LlmProvider get _provider => LlmProvider.forEndpoint(baseUrl);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    // Lets OpenRouter show the app by name in the human's activity list.
    if (_provider == LlmProvider.openRouter) 'X-Title': 'VoxCordis',
  };

  /// Lists model ids the server offers, for the Settings dropdown.
  Future<List<String>> listModels() async {
    final provider = _provider;
    final res = await _http.get(
      // Anthropic's list is native, not part of its OpenAI layer: it wants
      // its own key header and gives 20 models a page unless asked.
      provider == LlmProvider.anthropic
          ? _url('/models?limit=100')
          : _url('/models'),
      headers: {
        ..._headers,
        if (provider == LlmProvider.anthropic) ...{
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
      },
    );
    if (res.statusCode != 200) {
      throw LlmException('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = (jsonDecode(res.body) as Map)['data'] as List;
    final ids = [for (final m in data) (m as Map)['id'] as String];
    return provider == LlmProvider.openAi
        ? ids.where(isOpenAiChatModel).toList()
        : ids;
  }

  /// Streams one completion. Emits [TextDelta]s, then at most one
  /// [ToolCallsRequested] if the model wants tools run.
  Stream<LlmEvent> chat(
    List<Map<String, Object?>> messages, {
    List<Map<String, Object?>> tools = const [],
    Set<String> textTools = const {},
  }) async* {
    final req = http.Request('POST', _url('/chat/completions'))
      // A fresh connection per completion: llama-server may close a kept-alive
      // one after a long stream, which would fail the next tool round.
      ..persistentConnection = false
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
        ...sampling,
        if (stop.isNotEmpty) 'stop': stop,
        // OpenAI's newer models refuse max_tokens and want this instead.
        if (maxTokens != null)
          _provider == LlmProvider.openAi
                  ? 'max_completion_tokens'
                  : 'max_tokens':
              maxTokens,
        if (progress) 'return_progress': true,
        if (tools.isNotEmpty) 'tools': tools,
      });
    finishReason = null;
    // Without progress, llama-server sends the headers only once it starts
    // on the prompt, so this wait counts too.
    final first = firstWait;
    final res = first == null
        ? await _http.send(req)
        : await _http
              .send(req)
              .timeout(first, onTimeout: () => throw LlmStalled(first));
    if (res.statusCode != 200) {
      throw LlmException(
        'HTTP ${res.statusCode}: ${await res.stream.bytesToString()}',
      );
    }

    final pending = <int, ({String id, String name, StringBuffer args})>{};
    final think = ThinkSplitter();
    final inline = InlineToolCalls({
      ...textTools,
      for (final t in tools)
        ((t['function'] as Map?)?['name'] as String?) ?? '',
    });
    var shown = false;
    Iterable<LlmEvent> visible(Iterable<LlmEvent> events) sync* {
      for (final e in events) {
        if (e is TextDelta) {
          final text = inline.add(e.text);
          if (text.isNotEmpty) {
            shown = shown || text.trim().isNotEmpty;
            yield TextDelta(text);
          }
        } else {
          yield e;
        }
      }
    }

    final lines = watchdog(
      res.stream,
      first: firstWait,
      next: stallWait,
    ).transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;
      final json = jsonDecode(payload) as Map;
      if (json['error'] case final Map error) {
        throw LlmException('${error['message'] ?? error}');
      }
      if (json['prompt_progress'] case final Map p) {
        final total = (p['total'] as num?) ?? 0;
        final cache = (p['cache'] as num?) ?? 0;
        final done = (p['processed'] as num?) ?? 0;
        if (total > cache) {
          yield PromptProgress(
            ((done - cache) / (total - cache)).clamp(0, 1).toDouble(),
          );
        }
      }
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map;
      if (choice['finish_reason'] case final String reason) {
        finishReason = reason;
      }
      final delta = (choice['delta'] as Map?) ?? const {};

      // llama.cpp and LM Studio send reasoning_content, Ollama reasoning;
      // others leave <think>…</think> inline in the content.
      final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
      if (reasoning is String && reasoning.isNotEmpty) {
        yield ReasoningDelta(reasoning);
      }
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        yield* Stream.fromIterable(visible(think.add(content)));
      }

      for (final tc in (delta['tool_calls'] as List?) ?? const []) {
        final m = tc as Map;
        final i = (m['index'] as int?) ?? 0;
        final fn = (m['function'] as Map?) ?? const {};
        final entry = pending.putIfAbsent(
          i,
          () => (
            id: (m['id'] as String?) ?? 'call_$i',
            name: (fn['name'] as String?) ?? '',
            args: StringBuffer(),
          ),
        );
        entry.args.write(fn['arguments'] ?? '');
      }
    }
    yield* Stream.fromIterable(visible(think.flush()));
    final rest = inline.flush();
    if (rest.isNotEmpty) {
      shown = shown || rest.trim().isNotEmpty;
      yield TextDelta(rest);
    }
    // Some models wrap their whole reply in an invented tool call.
    if (!shown && inline.stray.isNotEmpty) {
      yield TextDelta(inline.stray.join('\n\n'));
    }
    if (pending.isNotEmpty) {
      yield ToolCallsRequested([
        for (final e in pending.values)
          ToolCall(e.id, e.name, e.args.toString()),
      ]);
    } else if (inline.calls.isNotEmpty) {
      yield ToolCallsRequested(inline.calls);
    }
  }
}

/// Whether OpenAI model [id] can chat. OpenAI's list also holds models for
/// pictures, speech and search, which would fail in a chat.
bool isOpenAiChatModel(String id) =>
    RegExp(r'^(gpt-|o\d|chatgpt-)').hasMatch(id) &&
    !RegExp(
      r'audio|realtime|transcribe|tts|image|search|embedding|moderation|instruct',
    ).hasMatch(id);

/// [source], failing with [LlmStalled] when the first chunk takes longer
/// than [first] or any later one longer than [next]. A server that hangs
/// mid-reply would otherwise leave the chat waiting forever.
Stream<T> watchdog<T>(Stream<T> source, {Duration? first, Duration? next}) {
  if (first == null && next == null) return source;
  final out = StreamController<T>();
  StreamSubscription<T>? sub;
  Timer? timer;
  var started = false;
  void arm(Duration? wait) {
    timer?.cancel();
    if (wait == null) return;
    timer = Timer(wait, () {
      sub?.cancel();
      out.addError(LlmStalled(wait));
      out.close();
    });
  }

  out.onListen = () {
    arm(first);
    sub = source.listen(
      (chunk) {
        started = true;
        arm(next);
        out.add(chunk);
      },
      onError: out.addError,
      onDone: () {
        timer?.cancel();
        out.close();
      },
    );
  };
  // A paused listener is busy, not a quiet server.
  out.onPause = () {
    timer?.cancel();
    sub?.pause();
  };
  out.onResume = () {
    arm(started ? next : first);
    sub?.resume();
  };
  out.onCancel = () {
    timer?.cancel();
    return sub?.cancel();
  };
  return out.stream;
}

/// Splits streamed content into reply text and an inline `<think>…</think>`
/// block at its start. Tags may arrive split across chunks.
class ThinkSplitter {
  static const _open = '<think>';
  static const _close = '</think>';

  final _held = StringBuffer();
  bool _thinking = false;
  bool _started = false; // past the point where a <think> could still open
  bool _afterThink = false; // drop the blank lines a model puts after </think>

  List<LlmEvent> add(String chunk) {
    _held.write(chunk);
    final out = <LlmEvent>[];
    var text = _held.toString();
    _held.clear();
    while (text.isNotEmpty) {
      if (_thinking) {
        final end = text.indexOf(_close);
        if (end >= 0) {
          if (end > 0) out.add(ReasoningDelta(text.substring(0, end)));
          text = text.substring(end + _close.length);
          _thinking = false;
          _started = true;
          _afterThink = true;
          continue;
        }
        final keep = _partialSuffix(text, _close);
        if (text.length > keep) {
          out.add(ReasoningDelta(text.substring(0, text.length - keep)));
        }
        _held.write(text.substring(text.length - keep));
        return out;
      }
      if (!_started) {
        final lead = text.trimLeft();
        if (lead.startsWith(_open)) {
          _thinking = true;
          text = lead.substring(_open.length);
          continue;
        }
        if (_open.startsWith(lead)) {
          _held.write(text); // could still become <think>
          return out;
        }
        _started = true;
      }
      if (_afterThink) {
        text = text.trimLeft();
        if (text.isEmpty) return out;
        _afterThink = false;
      }
      out.add(TextDelta(text));
      return out;
    }
    return out;
  }

  /// Whatever was held back waiting for a tag that never completed.
  List<LlmEvent> flush() {
    final rest = _held.toString();
    _held.clear();
    if (rest.isEmpty) return const [];
    return [_thinking ? ReasoningDelta(rest) : TextDelta(rest)];
  }

  /// Length of the longest end of [text] that is a start of [tag].
  static int _partialSuffix(String text, String tag) {
    for (var n = tag.length - 1; n > 0; n--) {
      if (text.endsWith(tag.substring(0, n))) return n;
    }
    return 0;
  }
}

/// Pulls `<tool_call>{"name": …, "arguments": …}</tool_call>` blocks out of
/// streamed reply text. Roleplay finetunes often write tool calls this way
/// (Hermes/ChatML style) without the server recognising them. Blocks that
/// are not valid JSON calls are dropped, never shown. Calls to tools not in
/// [known] are dropped too, but their text arguments are kept in [stray].
class InlineToolCalls {
  InlineToolCalls(this.known);

  final Set<String> known;
  static const _open = '<tool_call>';
  static const _close = '</tool_call>';

  final calls = <ToolCall>[];
  final stray = <String>[];
  final _held = StringBuffer();
  StringBuffer? _block;

  /// Returns the part of [chunk] that is safe to show.
  String add(String chunk) {
    _held.write(chunk);
    var text = _held.toString();
    _held.clear();
    final out = StringBuffer();
    while (text.isNotEmpty) {
      final block = _block;
      if (block != null) {
        final end = text.indexOf(_close);
        if (end < 0) {
          final keep = ThinkSplitter._partialSuffix(text, _close);
          block.write(text.substring(0, text.length - keep));
          _held.write(text.substring(text.length - keep));
          break;
        }
        block.write(text.substring(0, end));
        _finish(block.toString());
        _block = null;
        text = text.substring(end + _close.length);
        continue;
      }
      final start = text.indexOf(_open);
      if (start < 0) {
        final keep = ThinkSplitter._partialSuffix(text, _open);
        out.write(text.substring(0, text.length - keep));
        _held.write(text.substring(text.length - keep));
        break;
      }
      out.write(text.substring(0, start));
      _block = StringBuffer();
      text = text.substring(start + _open.length);
    }
    return out.toString();
  }

  /// Text held back for a tag that never completed. An unclosed block is
  /// still tried as a call (some models stop right before the closing tag).
  String flush() {
    final rest = _held.toString();
    _held.clear();
    final block = _block;
    _block = null;
    if (block != null) {
      _finish('$block$rest');
      return '';
    }
    return rest;
  }

  void _finish(String body) {
    try {
      final json = jsonDecode(body.trim());
      if (json is! Map || json['name'] is! String) return;
      final args = json['arguments'] ?? json['parameters'] ?? const {};
      final name = (json['name'] as String).trim();
      if (!known.contains(name)) {
        if (args is Map) stray.addAll(args.values.whereType<String>());
        return;
      }
      calls.add(
        ToolCall(
          'call_inline_${calls.length}',
          name,
          args is String ? args : jsonEncode(args),
        ),
      );
    } on FormatException {
      // Not a call after all; drop it.
    }
  }
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The server went quiet for too long.
class LlmStalled extends LlmException {
  LlmStalled(Duration wait)
    : super(
        'The model stopped responding (nothing for '
        '${wait.inSeconds >= 120 ? '${wait.inMinutes} minutes' : '${wait.inSeconds} seconds'}). '
        'Try again. If it keeps happening, a smaller model or a shorter '
        'memory span in Settings may help.',
      );
}
