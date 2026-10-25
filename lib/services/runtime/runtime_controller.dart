import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import 'download.dart';
import 'gpu_info.dart';
import 'llama_server.dart';
import 'model_catalog.dart';
import 'runtime_installer.dart';

enum RuntimeState { idle, installing, loading, ready, error, external }

/// Where chat requests go: the built-in server or the user's own.
typedef LlmTarget = ({String baseUrl, String model, String apiKey});

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
  ({String model, int ctx, bool gpu, String? template})? _serverConfig;
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
    final config = (
      model: modelPath,
      ctx: s.contextSize,
      gpu: s.useGpu,
      template: ChatFormat.templateFor(s),
    );
    final server = _server;
    if (server != null && _serverConfig == config) {
      return Future.value(_target(server));
    }
    return _starting ??= _start(config).whenComplete(() => _starting = null);
  }

  LlmTarget _target(LlamaServer s) =>
      (baseUrl: s.baseUrl, model: LlamaServer.modelAlias, apiKey: s.apiKey);

  Future<LlmTarget> _start(
    ({String model, int ctx, bool gpu, String? template}) config,
  ) async {
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
      await _killStale();
      final server = await LlamaServer.start(
        binary: binary,
        modelPath: config.model,
        contextSize: config.ctx,
        useGpu: config.gpu,
        chatTemplateFile: await _chatTemplateFile(config.template),
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

  File get _pidFile => File('${installer.installDir.parent.path}/server.pid');

  /// A crash or a killed app can leave a server behind holding GPU memory.
  /// Its pid was written down at start; stop it if it is still running.
  Future<void> _killStale() async {
    if (!await _pidFile.exists()) return;
    final pid = int.tryParse((await _pidFile.readAsString()).trim());
    await _pidFile.delete();
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
