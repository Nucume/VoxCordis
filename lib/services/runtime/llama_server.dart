import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// One running `llama-server` process serving a single model on localhost.
class LlamaServer {
  LlamaServer._(this._process, this.port, this.apiKey, this._log);

  final Process _process;
  final int port;

  /// A fresh secret per start. Any program on this machine, and any web
  /// page open in a browser, can reach a port on 127.0.0.1; without the key
  /// they could not read the chat or run the model.
  final String apiKey;
  final Queue<String> _log;

  /// The model alias every request uses.
  static const modelAlias = 'voxcordis';

  String get baseUrl => 'http://127.0.0.1:$port/v1';

  /// Last lines the server printed, for error messages.
  String get recentLog => _log.join('\n');

  Future<int> get exitCode => _process.exitCode;

  int get pid => _process.pid;

  /// Starts the server and waits until the model is loaded. With
  /// [embedding] it serves `/v1/embeddings` for an embedding model instead
  /// of chat.
  static Future<LlamaServer> start({
    required String binary,
    required String modelPath,
    int contextSize = 8192,
    bool useGpu = true,
    String? chatTemplateFile,
    String? mmprojPath,
    bool embedding = false,
    bool quantizeCache = true,
    Duration timeout = const Duration(minutes: 3),
    http.Client? client,
    void Function(int pid)? onSpawn,
  }) async {
    final port = await _freePort();
    final apiKey = newApiKey();
    final log = Queue<String>();
    final process = await Process.start(
      binary,
      [
        '-m', modelPath,
        '--host', '127.0.0.1',
        '--port', '$port',
        '-c', '$contextSize',
        // With the GPU on, llama.cpp's default (auto layers, --fit on) puts as
        // much of the model in graphics memory as fits and runs the rest on
        // the CPU, so a model too big for the card is slow rather than broken.
        if (!useGpu) ...['-ngl', '0'],
        if (embedding)
        // An embedding model reads each text whole, so one batch has to
        // hold a text as long as the context; mean pooling is what
        // EmbeddingGemma was trained with.
        ...[
          '--embedding',
          '--pooling',
          'mean',
          '-b',
          '$contextSize',
          '-ub',
          '$contextSize',
        ] else
          '--jinja', // tool calling (remember, update_memory, forget)
        if (chatTemplateFile != null) ...[
          '--chat-template-file',
          chatTemplateFile,
        ],
        // The vision file lets the model see pictures sent with a message.
        if (mmprojPath != null) ...[
          '--mmproj',
          mmprojPath,
          if (!useGpu) '--no-mmproj-offload',
        ],
        // The app talks to one chat at a time, so one slot: no memory is
        // set aside for requests that never come.
        '--parallel', '1',
        if (!embedding && quantizeCache) ...[
          // Flash attention is what lets the KV cache be stored as 8-bit,
          // which halves its memory (room for a longer span or a bigger
          // model) with almost no change in quality.
          '--flash-attn', 'on',
          '--cache-type-k', 'q8_0',
          '--cache-type-v', 'q8_0',
        ],
        '--no-webui',
        '--alias', modelAlias,
      ],
      workingDirectory: File(binary).parent.path,
      // Passed through the environment rather than the command line, which
      // other users on the machine can list.
      environment: {'LLAMA_API_KEY': apiKey},
    );
    onSpawn?.call(process.pid);

    void keep(String line) {
      log.addLast(line);
      while (log.length > 40) {
        log.removeFirst();
      }
    }

    for (final s in [process.stdout, process.stderr]) {
      s
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(keep, onError: (_) {});
    }

    final server = LlamaServer._(process, port, apiKey, log);
    final http.Client c = client ?? http.Client();
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(timeout);
    try {
      while (true) {
        if (exited) {
          throw LlamaServerException(
            'The runtime stopped while loading the model.',
            server.recentLog,
          );
        }
        if (DateTime.now().isAfter(deadline)) {
          await server.stop();
          throw LlamaServerException(
            'The model took too long to load.',
            server.recentLog,
          );
        }
        try {
          final res = await c
              .get(Uri.parse('http://127.0.0.1:$port/health'))
              .timeout(const Duration(seconds: 2));
          if (res.statusCode == 200) return server;
        } catch (_) {
          // Not listening yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      if (client == null) c.close();
    }
  }

  /// Whether the app stopped this server itself, rather than it crashing.
  bool get stopRequested => _stopRequested;
  bool _stopRequested = false;

  Future<void> stop() async {
    _stopRequested = true;
    _process.kill();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
  }

  static String newApiKey() {
    final r = Random.secure();
    return base64Url
        .encode([for (var i = 0; i < 24; i++) r.nextInt(256)])
        .replaceAll('=', '');
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }
}

/// Plain words for why a server that ended with exit [code] stopped, from
/// the last lines it printed ([log]).
String serverExitHint(int code, String log) {
  final lines = log.split('\n');
  final lower = log.toLowerCase();
  if (const [
    'out of memory',
    'failed to allocate',
    'unable to allocate',
    'erroroutofdevicememory',
    'erroroutofhostmemory',
    'bad_alloc',
  ].any(lower.contains)) {
    return 'it ran out of memory';
  }
  if (lower.contains('devicelost') || lower.contains('device lost')) {
    return 'the graphics driver stopped it';
  }
  // The system's out-of-memory killer on Linux and macOS.
  if (code == -9 && !Platform.isWindows) {
    return 'the system stopped it, most likely for lack of memory';
  }
  final hint = lines.lastWhere(
    (l) =>
        l.toLowerCase().contains('error') ||
        l.contains('failed') ||
        l.contains('GGML_ASSERT') ||
        l.contains('terminate called'),
    orElse: () => '',
  );
  // Windows codes read best in hex, like 0xC0000005.
  final shown = Platform.isWindows && code < 0
      ? '0x${(code & 0xFFFFFFFF).toRadixString(16).toUpperCase()}'
      : '$code';
  if (hint.trim().isEmpty) return 'it crashed (exit code $shown)';
  final line = hint.trim();
  return 'it crashed (exit code $shown: '
      '${line.length > 200 ? '${line.substring(0, 200)}…' : line})';
}

class LlamaServerException implements Exception {
  LlamaServerException(this.message, this.log);
  final String message;
  final String log;

  @override
  String toString() {
    final hint = log
        .split('\n')
        .lastWhere(
          (l) => l.toLowerCase().contains('error') || l.contains('failed'),
          orElse: () => '',
        );
    return hint.isEmpty ? message : '$message ($hint)';
  }
}
