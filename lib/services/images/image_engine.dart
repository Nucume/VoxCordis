import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import '../invoke_client.dart';
import '../logs/app_log.dart';
import '../runtime/download.dart';
import '../runtime/runtime_controller.dart';
import 'image_catalog.dart';
import 'sd_runtime.dart';

/// A picture asked for, by the companion or by hand in the Images tab.
class DrawJob {
  DrawJob(this.request, {required this.folder, this.forChat = true});

  final DrawRequest request;

  /// The companion folder the picture goes into, under `images/`.
  final String folder;

  /// Whether it goes into the chat when done, rather than only the
  /// Images tab.
  final bool forChat;

  final _done = Completer<File>();

  /// The picture, or the error that stopped it.
  Future<File> get done => _done.future;
}

/// Draws pictures with stable-diffusion.cpp, one at a time, after the reply
/// that asked for them is written. Also downloads the engine and the
/// picture models.
class ImageEngine extends ChangeNotifier {
  ImageEngine({
    required this.supportDir,
    required this.runtime,
    required this.settings,
    http.Client? client,
    SdInstaller? installer,
    this.findExe,
  }) : _http = client ?? http.Client(),
       installer = installer ?? SdInstaller(supportDir, client: client);

  final Directory supportDir;
  final RuntimeController runtime;
  final AppSettings Function() settings;
  final http.Client _http;
  final SdInstaller installer;

  /// Where sd-cli is, in place of installing it; for tests.
  @visibleForTesting
  Future<String> Function(AppSettings s)? findExe;

  /// Settings → Logs; set by the app.
  AppLog? log;

  /// Called with each picture drawn for the chat, to show it there.
  Future<void> Function(DrawJob job, File picture)? onDrawn;

  /// Called when a picture for the chat couldn't be drawn.
  void Function(DrawJob job, Object error)? onFailed;

  final _queue = <DrawJob>[];
  DrawJob? current;

  /// What the current job is doing, for the status line.
  String? status;

  /// 0..1 through the current picture's steps, or null.
  double? progress;

  Completer<void>? _cancel;

  /// Downloads in flight: model id (or "engine") → progress 0..1, or null.
  final Map<String, double?> downloads = {};
  final Set<String> _cancelled = {};

  int get waiting => _queue.length;
  bool get busy => current != null;

  /// What Invoke had when last asked, for [invokeUrl].
  ({List<InvokeModel> models, List<InvokeModel> loras})? invokeCatalog;
  String? invokeUrl;

  /// Why Invoke's models couldn't be read, if they couldn't.
  String? invokeError;

  InvokeClient invokeFor(AppSettings s) =>
      InvokeClient(s.invokeUrl, client: _http);

  /// Asks Invoke what it has. Quiet when it isn't running.
  Future<void> refreshInvoke(AppSettings s) async {
    try {
      invokeCatalog = await invokeFor(s).catalog();
      invokeError = null;
    } catch (e) {
      if (invokeError != '$e') {
        log?.add(LogKind.drawing, 'Invoke isn\'t answering: $e', error: true);
      }
      invokeCatalog = null;
      invokeError = '$e';
    }
    invokeUrl = s.invokeUrl;
    notifyListeners();
  }

  ({List<InvokeModel> models, List<InvokeModel> loras})? _invoke(
    AppSettings s,
  ) => invokeUrl == s.invokeUrl ? invokeCatalog : null;

  /// The picture models the companion can draw with now.
  List<ImageModel> available(AppSettings s) =>
      s.imageEngine == ImageEngineChoice.invoke
      ? [for (final m in _invoke(s)?.models ?? const []) m.asImageModel]
      : ImageCatalog.available(ImageCatalog.dirFor(s));

  /// The LoRAs it can add, with what each is for.
  List<({String name, String note})> lorasFor(AppSettings s) =>
      s.imageEngine == ImageEngineChoice.invoke
      ? [
          for (final l in _invoke(s)?.loras ?? const [])
            (name: l.name, note: l.note),
        ]
      : ImageCatalog.loras(ImageCatalog.lorasFor(s));

  /// Queues [job]; it starts once nothing else is drawing and no reply is
  /// being written.
  DrawJob draw(DrawJob job) {
    _queue.add(job);
    notifyListeners();
    unawaited(_pump());
    return job;
  }

  /// Stops the picture being drawn and drops the ones waiting.
  void cancelAll() {
    for (final j in _queue) {
      j._done.completeError(SdException('Drawing was stopped.'));
    }
    _queue.clear();
    if (_cancel case final c? when !c.isCompleted) c.complete();
    notifyListeners();
  }

  bool _pumping = false;

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        current = job;
        progress = null;
        status = 'Waiting for the reply to finish';
        notifyListeners();
        final started = DateTime.now();
        try {
          final file = await _run(job);
          log?.add(
            LogKind.drawing,
            'Drew ${p.basename(file.path)} in '
            '${DateTime.now().difference(started).inSeconds} s',
            details: file.path,
          );
          job._done.complete(file);
          if (job.forChat) await onDrawn?.call(job, file);
        } catch (e) {
          log?.add(
            LogKind.drawing,
            'Drawing failed: $e',
            details: e is SdException ? e.output : '',
            error: true,
          );
          job._done.completeError(e);
          job.done.ignore();
          if (job.forChat) onFailed?.call(job, e);
        }
      }
    } finally {
      current = null;
      status = null;
      progress = null;
      _pumping = false;
      notifyListeners();
    }
  }

  Future<File> _run(DrawJob job) async {
    // The reply that asked for it is still being written.
    while (runtime.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final s = settings();
    final viaInvoke = s.imageEngine == ImageEngineChoice.invoke;
    final exe = viaInvoke ? '' : await (findExe?.call(s) ?? _ensureEngine(s));
    final done = Completer<void>();
    if (s.freeGpuForDrawing && s.useGpu && s.llmMode == LlmMode.builtIn) {
      status = 'Making room on the graphics card';
      notifyListeners();
      await runtime.freeForDrawing(done.future);
    }
    _cancel = Completer<void>();
    try {
      status = 'Drawing';
      progress = 0;
      notifyListeners();
      final stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
      var out = File(p.join(job.folder, 'images', 'drawn-$stamp.png'));
      for (var n = 2; await out.exists(); n++) {
        out = File(p.join(job.folder, 'images', 'drawn-$stamp-$n.png'));
      }
      final seed = job.request.seed ?? Random().nextInt(1 << 31);
      final r = job.request;
      log?.add(
        LogKind.drawing,
        'Drawing with ${r.model.name}${viaInvoke ? ' in Invoke' : ''} '
        '(${r.shape}, seed $seed)',
        details: [
          'Prompt: ${r.prompt}',
          if (r.negative.isNotEmpty) 'Negative: ${r.negative}',
          if (r.loras.isNotEmpty)
            'LoRAs: ${r.loras.map((l) => '${l.name} ${l.weight}').join(', ')}',
        ].join('\n'),
      );
      if (viaInvoke) {
        status = 'Drawing in Invoke';
        progress = null;
        notifyListeners();
        await out.parent.create(recursive: true);
        return await out.writeAsBytes(
          await _drawInInvoke(s, job.request, seed, _cancel!.future),
        );
      }
      return await SdRun.run(
        exe,
        job.request,
        modelsDir: ImageCatalog.dirFor(s),
        lorasDir: ImageCatalog.lorasFor(s),
        out: out,
        seed: seed,
        cancel: _cancel!.future,
        onProgress: (f) {
          progress = f;
          notifyListeners();
        },
      );
    } finally {
      _cancel = null;
      done.complete();
    }
  }

  Future<Uint8List> _drawInInvoke(
    AppSettings s,
    DrawRequest r,
    int seed,
    Future<void> cancel,
  ) async {
    if (_invoke(s) == null) await refreshInvoke(s);
    final catalog = _invoke(s);
    if (catalog == null) {
      throw InvokeException(
        'Invoke isn\'t answering at ${s.invokeUrl}. Is it running?',
      );
    }
    final key = r.model.id.substring(InvokeClient.idPrefix.length);
    final model = catalog.models.where((m) => m.key == key).firstOrNull;
    if (model == null) {
      throw InvokeException('${r.model.name} isn\'t in Invoke any more.');
    }
    final loras = [
      for (final l in r.loras)
        if (catalog.loras.where((x) => x.name == l.name).firstOrNull
            case final lora?)
          (lora: lora, weight: l.weight),
    ];
    final mismatched = loras.where((l) => l.lora.base != model.base);
    if (mismatched.isNotEmpty) {
      throw InvokeException(
        '${mismatched.map((l) => l.lora.name).join(', ')} is for '
        '${mismatched.first.lora.baseLabel}, not ${model.baseLabel} like '
        '${model.name}.',
      );
    }
    return invokeFor(
      s,
    ).draw(r, model: model, loras: loras, seed: seed, cancel: cancel);
  }

  Future<String> _ensureEngine(AppSettings s) async {
    final found = await installer.find(gpu: s.useGpu);
    if (found != null) return found;
    status = 'Setting up drawing';
    downloads['engine'] = null;
    notifyListeners();
    try {
      return await installer.ensureInstalled(
        gpu: s.useGpu,
        onProgress: (got, total) {
          downloads['engine'] = total == null ? null : got / total;
          notifyListeners();
        },
      );
    } finally {
      downloads.remove('engine');
      notifyListeners();
    }
  }

  /// Downloads every missing file of [m] into the picture models folder.
  Future<void> download(ImageModel m) async {
    final dir = ImageCatalog.dirFor(settings());
    downloads[m.id] = null;
    _cancelled.remove(m.id);
    notifyListeners();
    try {
      final total = m.sizeGb * 1e9;
      var done = 0.0;
      for (final f in m.files) {
        final target = ImageCatalog.fileIn(dir, f);
        if (await target.exists()) {
          done += f.sizeGb * 1e9;
          continue;
        }
        final file = await downloadFile(
          _http,
          f.url,
          target,
          onProgress: (got, _) {
            downloads[m.id] = ((done + got) / total).clamp(0.0, 0.99);
            notifyListeners();
          },
          isCancelled: () => _cancelled.contains(m.id),
        );
        await verifySha256(file, f.sha256);
        done += f.sizeGb * 1e9;
      }
    } finally {
      downloads.remove(m.id);
      notifyListeners();
    }
  }

  void cancelDownload(String id) => _cancelled.add(id);

  /// Deletes [m]'s files, except parts another downloaded model still
  /// uses.
  Future<void> delete(ImageModel m) async {
    final dir = ImageCatalog.dirFor(settings());
    final kept = {
      for (final other in ImageCatalog.models)
        if (other.id != m.id && ImageCatalog.installed(dir, other))
          for (final f in other.files) f.fileName,
    };
    for (final f in m.files) {
      if (kept.contains(f.fileName)) continue;
      final file = ImageCatalog.fileIn(dir, f);
      if (await file.exists()) await file.delete();
    }
    notifyListeners();
  }
}
