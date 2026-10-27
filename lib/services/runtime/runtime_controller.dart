import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import '../llm_client.dart';
import '../recall/embedder.dart';
import 'download.dart';
import 'gpu_info.dart';
import 'llama_server.dart';
import 'model_catalog.dart';
import 'runtime_installer.dart';

enum RuntimeState { idle, installing, loading, ready, error, external }

/// Where chat requests go: the built-in server or the user's own.
typedef LlmTarget = ({String baseUrl, String model, String apiKey});

typedef _ServerConfig = ({
  String model,
  int ctx,
  bool gpu,
  String? template,
  String? mmproj,
});

/// Owns the built-in llama.cpp runtime: installs it on first use, starts it
/// with the chosen model, restarts it when the model changes, stops it on exit.
/// Also runs model downloads.
class RuntimeController extends ChangeNotifier {
  RuntimeController(this.supportDir, {http.Client? client})
    : _http = client ?? http.Client(),
      installer = RuntimeInstaller(supportDir, client: client);

  final Directory supportDir;
  final http.Client _http;
  final RuntimeInstaller installer;

  /// The graphics card, looked up once, for model recommendations.
  late final Future<GpuInfo> gpu = GpuInfo.detect();

  RuntimeState state = RuntimeState.idle;

  /// 0..1 while installing, null when unknown.
  double? progress;
  String? error;

  LlamaServer? _server;
  _ServerConfig? _serverConfig;
  Future<LlmTarget>? _starting;

  /// Catalog downloads in flight: model id → progress 0..1 (or null).
  final Map<String, double?> downloads = {};
  final Set<String> _cancelled = {};

  String get statusText => switch (state) {
    RuntimeState.idle => 'Model sleeping',
    RuntimeState.installing =>
      'Setting up runtime${progress == null ? '' : ' ${(progress! * 100).round()}%'}',
    RuntimeState.loading => 'Loading model…',
    RuntimeState.ready => 'Ready',
    RuntimeState.error => 'Runtime error',
    RuntimeState.external => 'External server',
  };

  /// Makes sure something can answer chat requests and says where.
  Future<LlmTarget> ensureReady(AppSettings s) {
    if (s.llmMode == LlmMode.external) {
      if (_server != null) unawaited(stop());
      _set(RuntimeState.external);
      return Future.value((
        baseUrl: s.llmEndpoint,
        model: s.llmModel,
        apiKey: s.llmApiKey,
      ));
    }
    final modelPath = s.modelPath;
    if (modelPath == null) {
      return Future.error(StateError('Choose a model in Settings first.'));
    }
    // A picture is being drawn with the graphics card to itself.
    if (_drawing case final drawing?) {
      return drawing.then((_) => ensureReady(s));
    }
    final config = (
      model: modelPath,
      ctx: s.contextSize,
      gpu: s.useGpu,
      template: ChatFormat.templateFor(s),
      mmproj: ModelCatalog.mmprojFor(s),
    );
    final server = _server;
    if (server != null && _serverConfig == config) {
      return Future.value(_target(server));
    }
    return _starting ??= _start(config).whenComplete(() => _starting = null);
  }

  LlmTarget _target(LlamaServer s) =>
      (baseUrl: s.baseUrl, model: LlamaServer.modelAlias, apiKey: s.apiKey);

  Future<LlmTarget> _start(_ServerConfig config) async {
    error = null;
    try {
      await stop();
      if (!await File(config.model).exists()) {
        throw StateError('Model file not found: ${config.model}');
      }
      var binary = await installer.find();
      if (binary == null) {
        progress = null;
        _set(RuntimeState.installing);
        binary = await installer.ensureInstalled(
          onProgress: (got, total) {
            progress = total == null ? null : got / total;
            notifyListeners();
          },
        );
      }
      _set(RuntimeState.loading);
      await _killStale(_pidFile);
      final server = await LlamaServer.start(
        binary: binary,
        modelPath: config.model,
        contextSize: config.ctx,
        useGpu: config.gpu,
        chatTemplateFile: await _chatTemplateFile(config.template),
        mmprojPath: config.mmproj,
        timeout: _loadTimeout(config.model),
        onSpawn: (pid) {
          _pidFile.parent.createSync(recursive: true);
          _pidFile.writeAsStringSync('$pid');
        },
      );
      _server = server;
      _serverConfig = config;
      unawaited(
        server.exitCode.then((_) {
          if (_server != server) return;
          _server = null;
          _serverConfig = null;
          error = 'The runtime stopped unexpectedly.';
          _set(RuntimeState.error);
        }),
      );
      _set(RuntimeState.ready);
      return _target(server);
    } catch (e) {
      error = '$e';
      _set(RuntimeState.error);
      rethrow;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _serverConfig = null;
    if (s != null) {
      await s.stop();
      if (await _pidFile.exists()) await _pidFile.delete();
    }
    if (state == RuntimeState.ready) _set(RuntimeState.idle);
  }

  Timer? _idleTimer;
  int _holds = 0;

  /// How long without typing before [AppSettings.freeGpuWhenIdle] unloads
  /// the models.
  static const idleUnload = Duration(seconds: 60);

  /// The human is active (typing, or a reply just ended). With
  /// [AppSettings.freeGpuWhenIdle] on, the built-in model loads if it was
  /// let go ([warm]), and both models unload after [idleUnload] of quiet.
  void touch(AppSettings s, {bool warm = false}) {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (s.llmMode != LlmMode.builtIn || !s.freeGpuWhenIdle) return;
    if (warm && _server == null && s.modelPath != null && _drawing == null) {
      ensureReady(s).ignore();
    }
    if (_holds > 0) return;
    _idleTimer = Timer(idleUnload, () {
      _idleTimer = null;
      if (_holds == 0) unawaited(freeGpu());
    });
  }

  /// Keeps the models loaded while a reply or rewrite runs; pair with
  /// [release].
  void hold() {
    _holds++;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// A reply or rewrite is running.
  bool get busy => _holds > 0;

  Future<void>? _drawing;

  /// Unloads the chat model and Eyes, and keeps them unloaded until [done]
  /// completes: a picture is drawn meanwhile.
  Future<void> freeForDrawing(Future<void> done) async {
    final drawing = done.whenComplete(() => _drawing = null);
    _drawing = drawing;
    drawing.ignore();
    await freeGpu();
  }

  /// Whether the models are set to unload when nothing happens.
  @visibleForTesting
  bool get idleUnloadPending => _idleTimer != null;

  void release(AppSettings s) {
    if (_holds > 0) _holds--;
    touch(s);
  }

  /// Stops the chat model and Eyes, which hold graphics memory. Recall
  /// stays: it runs on the processor and is let go on its own.
  Future<void> freeGpu() async {
    await stopEyes();
    await stop();
  }

  /// Stops the chat model, Eyes and Recall, when the app closes.
  Future<void> stopAll() async {
    await freeGpu();
    await stopRecall();
  }

  File get _pidFile => File('${installer.installDir.parent.path}/server.pid');
  File get _eyesPidFile => File('${installer.installDir.parent.path}/eyes.pid');
  File get _recallPidFile =>
      File('${installer.installDir.parent.path}/recall.pid');

  LlamaServer? _recall;
  String? _recallConfig;
  Future<LlamaServer>? _recallStarting;
  Timer? _recallIdle;

  /// How long Recall stays loaded after its last use. It lives in main
  /// memory (about half a gigabyte), not on the graphics card.
  static const recallIdle = Duration(minutes: 10);

  /// Recall's embedding server, loaded on first use and let go again after
  /// [recallIdle] without one. Throws when Recall isn't downloaded.
  Future<LlamaServer> ensureRecall(AppSettings s) {
    final path = ModelCatalog.recallFile(s);
    if (path == null) throw StateError('Recall is not downloaded.');
    _recallIdle?.cancel();
    _recallIdle = Timer(recallIdle, () => unawaited(stopRecall()));
    final running = _recall;
    if (running != null && _recallConfig == path) return Future.value(running);
    return _recallStarting ??= () async {
      await stopRecall(keepTimer: true);
      final binary =
          await installer.find() ?? await installer.ensureInstalled();
      await _killStale(_recallPidFile);
      final server = await LlamaServer.start(
        binary: binary,
        modelPath: path,
        embedding: true,
        // What EmbeddingGemma reads at most; texts are cut to fit.
        contextSize: Embedder.contextSize,
        // On the processor: a text embeds in a moment there, and the
        // graphics card stays the chat model's.
        useGpu: false,
        onSpawn: (pid) {
          _recallPidFile.parent.createSync(recursive: true);
          _recallPidFile.writeAsStringSync('$pid');
        },
      );
      _recall = server;
      _recallConfig = path;
      unawaited(
        server.exitCode.then((_) {
          if (_recall != server) return;
          _recall = null;
          _recallConfig = null;
        }),
      );
      return server;
    }().whenComplete(() => _recallStarting = null);
  }

  /// Unloads Recall.
  Future<void> stopRecall({bool keepTimer = false}) async {
    if (!keepTimer) {
      _recallIdle?.cancel();
      _recallIdle = null;
    }
    final s = _recall;
    _recall = null;
    _recallConfig = null;
    if (s != null) {
      await s.stop();
      if (await _recallPidFile.exists()) await _recallPidFile.delete();
    }
  }

  /// A crash or a killed app can leave a server behind holding GPU memory.
  /// Its pid was written down at start; stop it if it is still running.
  Future<void> _killStale(File pidFile) async {
    if (!await pidFile.exists()) return;
    final pid = int.tryParse((await pidFile.readAsString()).trim());
    await pidFile.delete();
    if (pid == null || !await _isLlamaServer(pid)) return;
    Process.killPid(pid);
  }

  static Future<bool> _isLlamaServer(int pid) async {
    try {
      final String name;
      if (Platform.isLinux) {
        name = await File('/proc/$pid/cmdline').readAsString();
      } else if (Platform.isWindows) {
        name =
            (await Process.run('tasklist', [
                  '/FI',
                  'PID eq $pid',
                  '/NH',
                ])).stdout
                as String;
      } else {
        name =
            (await Process.run('ps', ['-p', '$pid', '-o', 'comm='])).stdout
                as String;
      }
      return name.contains('llama-server');
    } catch (_) {
      return false; // no such process
    }
  }

  LlamaServer? _eyes;
  String? _eyesConfig;
  Future<LlamaServer>? _eyesStarting;
  Timer? _eyesIdle;

  /// How long Eyes stays loaded after looking, for the next picture.
  static const eyesIdle = Duration(minutes: 3);

  /// What Eyes is asked for each picture.
  static const describePrompt =
      'Describe this picture for someone who can\'t see it, so they can '
      'talk about it as if they saw it. Say what kind of picture it is (a '
      'photo, drawing, screenshot, meme…), who and what is in it, what they '
      'look like and wear, what is happening, the setting, colours and mood, '
      'and any text in it word for word. Describe everything plainly and '
      'factually, nudity and sexual content included, without judging, '
      'refusing or adding warnings. Don\'t guess who real people are, and '
      'describe only the picture, not their words. Write plain prose in at '
      'most 200 words.';

  /// Has Eyes, the small vision model, describe a picture ([dataUrl], from
  /// [Sight.dataUrl]). [said] is what the human wrote with it, which can
  /// point Eyes at what matters. Loads Eyes the first time, and lets it go
  /// again after [eyesIdle].
  Future<String> describePicture(
    AppSettings s,
    String dataUrl, {
    String said = '',
  }) async {
    final files = ModelCatalog.eyesFiles(s);
    if (files == null) throw StateError('Eyes is not downloaded.');
    _eyesIdle?.cancel();
    try {
      final server = await _ensureEyes(files, s.useGpu);
      final client = LlmClient(
        baseUrl: server.baseUrl,
        model: LlamaServer.modelAlias,
        apiKey: server.apiKey,
        sampling: ModelCatalog.eyes.sampling,
        maxTokens: 600,
        firstWait: const Duration(minutes: 5),
        stallWait: const Duration(seconds: 90),
        client: http.Client(),
      );
      final text = StringBuffer();
      await for (final e in client.chat([
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': said.trim().isEmpty
                  ? describePrompt
                  : '$describePrompt\n\nThey shared it with these words, '
                        'which may say what to look at: "${said.trim()}"',
            },
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
        },
      ])) {
        if (e is TextDelta) text.write(e.text);
      }
      final description = text.toString().trim();
      if (description.isEmpty) throw StateError('Eyes saw nothing.');
      return description;
    } finally {
      _eyesIdle = Timer(eyesIdle, () => unawaited(stopEyes()));
    }
  }

  Future<LlamaServer> _ensureEyes(
    ({String model, String mmproj}) files,
    bool gpu,
  ) {
    final config = '${files.model}|${files.mmproj}|$gpu';
    final running = _eyes;
    if (running != null && _eyesConfig == config) {
      return Future.value(running);
    }
    return _eyesStarting ??= () async {
      await stopEyes();
      final binary =
          await installer.find() ?? await installer.ensureInstalled();
      await _killStale(_eyesPidFile);
      final server = await LlamaServer.start(
        binary: binary,
        modelPath: files.model,
        mmprojPath: files.mmproj,
        // Room for one large picture and the description.
        contextSize: 8192,
        useGpu: gpu,
        timeout: _loadTimeout(files.model),
        onSpawn: (pid) {
          _eyesPidFile.parent.createSync(recursive: true);
          _eyesPidFile.writeAsStringSync('$pid');
        },
      );
      _eyes = server;
      _eyesConfig = config;
      unawaited(
        server.exitCode.then((_) {
          if (_eyes != server) return;
          _eyes = null;
          _eyesConfig = null;
        }),
      );
      return server;
    }().whenComplete(() => _eyesStarting = null);
  }

  /// Unloads Eyes, freeing its memory.
  Future<void> stopEyes() async {
    _eyesIdle?.cancel();
    _eyesIdle = null;
    final s = _eyes;
    _eyes = null;
    _eyesConfig = null;
    if (s != null) {
      await s.stop();
      if (await _eyesPidFile.exists()) await _eyesPidFile.delete();
    }
  }

  /// Downloads a catalog model (every part of a split one) into [modelsDir];
  /// returns the path llama-server loads.
  Future<String> download(CatalogModel m, Directory modelsDir) async {
    downloads[m.id] = null;
    _cancelled.remove(m.id);
    notifyListeners();
    try {
      // Progress over all parts, measured against the catalog size.
      final expected = m.sizeGb * 1e9;
      var done = 0;
      late File file;
      for (final path in m.allFiles) {
        file = await downloadFile(
          _http,
          m.urlFor(path),
          ModelCatalog.partFor(modelsDir, path),
          onProgress: (got, total) {
            downloads[m.id] = m.parts.isEmpty
                ? (total == null ? null : got / total)
                : ((done + got) / expected).clamp(0.0, 0.99);
            notifyListeners();
          },
          isCancelled: () => _cancelled.contains(m.id),
        );
        await verifySha256(file, m.sha256[path]!);
        done += await file.length();
      }
      return file.path;
    } finally {
      downloads.remove(m.id);
      notifyListeners();
    }
  }

  /// Three minutes, plus one per 10 GB of model spread over all its parts,
  /// so a huge split model has time to come off the disk.
  /// Writes the catalog model's replacement chat template next to the
  /// models, for llama-server to read. Null when the GGUF's own one is used.
  Future<String?> _chatTemplateFile(String? name) async {
    if (name == null) return null;
    final text = await rootBundle.loadString(
      'assets/chat_templates/$name.jinja',
    );
    final file = File(p.join(supportDir.path, 'chat_templates', '$name.jinja'));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return file.path;
  }

  static Duration _loadTimeout(String modelPath) {
    final file = File(modelPath);
    var bytes = 0;
    final split = RegExp(r'-\d{5}-of-\d{5}\.gguf$');
    try {
      if (split.hasMatch(modelPath)) {
        final prefix = modelPath.replaceFirst(split, '');
        for (final e in file.parent.listSync()) {
          if (e is File &&
              e.path.startsWith(prefix) &&
              split.hasMatch(e.path)) {
            bytes += e.lengthSync();
          }
        }
      } else {
        bytes = file.lengthSync();
      }
    } catch (_) {
      // Missing file: llama-server reports it.
    }
    return Duration(minutes: 3 + bytes ~/ 10e9);
  }

  void cancelDownload(String id) => _cancelled.add(id);

  void _set(RuntimeState s) {
    state = s;
    notifyListeners();
  }
}
