import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import '../invoke_client.dart';
import '../logs/app_log.dart';
import '../runtime/download.dart';
import '../import/soulkyn_media.dart';
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
       installer = installer ?? SdInstaller(supportDir, client: client) {
    // Which sd-cli draws, and why not CUDA, goes to Settings → Logs.
    this.installer.note ??= (m) => log?.add(LogKind.drawing, m);
  }

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

  /// Queues turning [image] into a clip with the first video model that is
  /// downloaded; null when there is none or the engine is Invoke.
  Future<DrawJob?> animate(
    File image, {
    required String folder,
    String prompt = '',
    int seconds = 4,
    String? modelId,
  }) async {
    final s = settings();
    if (s.imageEngine != ImageEngineChoice.builtIn) return null;
    final ready = ImageCatalog.availableVideo(ImageCatalog.videoFor(s));
    final model =
        ready.where((m) => m.id == modelId).firstOrNull ?? ready.firstOrNull;
    if (model == null) return null;
    return draw(
      DrawJob(
        AnimateRequest(
          model: model,
          prompt: prompt.trim().isEmpty ? 'the scene comes to life' : prompt,
          image: image,
          frames: model.framesFor(seconds),
          shape: await shapeOf(image),
        ),
        folder: folder,
        forChat: false,
      ),
    );
  }

  /// "portrait", "landscape" or "square", from the proportions of [image].
  static Future<String> shapeOf(File image) async {
    final codec = await ui.instantiateImageCodec(await image.readAsBytes());
    try {
      final f = (await codec.getNextFrame()).image;
      final ratio = f.width / f.height;
      f.dispose();
      return ratio < 0.85
          ? 'portrait'
          : ratio > 1.18
          ? 'landscape'
          : 'square';
    } finally {
      codec.dispose();
    }
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
            '${job.request is AnimateRequest ? 'Made' : 'Drew'} '
            '${p.basename(file.path)} in '
            '${DateTime.now().difference(started).inSeconds} s',
            details: [file.path, ..._output].join('\n'),
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

  /// What sd-cli printed for the current job, for Settings → Logs: when a
  /// clip comes out wrong, this is what says why.
  final _output = <String>[];

  Future<File> _run(DrawJob job) async {
    _output.clear();
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
      // A reply may have started while the engine was found; unloading the
      // model now would cut it off. Nothing waits between this check and
      // freeForDrawing, which makes later replies wait for the picture.
      while (runtime.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await runtime.freeForDrawing(done.future);
    }
    _cancel = Completer<void>();
    try {
      final clip = job.request is AnimateRequest;
      if (clip && viaInvoke) {
        throw SdException('Clips need the built-in drawing, not Invoke.');
      }
      status = clip ? 'Making a clip' : 'Drawing';
      progress = 0;
      notifyListeners();
      final stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
      final name = clip ? 'animated' : 'drawn';
      final ext = clip ? 'webm' : 'png';
      var out = File(p.join(job.folder, 'images', '$name-$stamp.$ext'));
      for (var n = 2; await out.exists(); n++) {
        out = File(p.join(job.folder, 'images', '$name-$stamp-$n.$ext'));
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
      var sampling = false;
      Future<File> runWith(String exe) => SdRun.run(
        exe,
        job.request,
        modelsDir: job.request is AnimateRequest
            ? ImageCatalog.videoFor(s)
            : ImageCatalog.dirFor(s),
        lorasDir: ImageCatalog.lorasFor(s),
        out: out,
        seed: seed,
        cancel: _cancel!.future,
        onLine: (line) {
          if (_output.length < 300) _output.add(line);
        },
        onProgress: (f) {
          sampling = true;
          progress = f;
          notifyListeners();
        },
      );
      File made;
      try {
        made = await runWith(exe);
      } on SdException catch (e) {
        // CUDA that won't start (an old driver, a card it doesn't know)
        // falls back to Vulkan, once, and stays off for a day.
        if (!installer.isCuda(exe) ||
            sampling ||
            !SdRun.cudaWontStart(e.output)) {
          rethrow;
        }
        await installer.giveUpOnCuda(e.message);
        _output.add('--- trying again with Vulkan ---');
        made = await runWith(await _ensureEngine(s));
      }
      if (r is AnimateRequest) await keepThumbnail(r.image, made);
      return made;
    } finally {
      _cancel = null;
      done.complete();
    }
  }

  /// The clip's poster for the gallery's tile: a copy of the picture it was
  /// made from, where the gallery looks for posters.
  static File thumbnailOf(File clip) => File(
    p.join(
      clip.parent.path,
      SoulkynMediaDownload.postersFolder,
      '${p.basenameWithoutExtension(clip.path)}.png',
    ),
  );

  @visibleForTesting
  static Future<void> keepThumbnail(File source, File clip) async {
    final thumb = thumbnailOf(clip);
    await thumb.parent.create(recursive: true);
    await source.copy(thumb.path);
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
    final dir = m is VideoModel
        ? ImageCatalog.videoFor(settings())
        : ImageCatalog.dirFor(settings());
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
        final source = File(p.join(dir.path, f.sourceName));
        final file = await downloadFile(
          _http,
          f.url,
          source,
          onProgress: (got, _) {
            downloads[m.id] = ((done + got) / total).clamp(0.0, 0.99);
            notifyListeners();
          },
          isCancelled: () => _cancelled.contains(m.id),
        );
        await verifySha256(file, f.sha256);
        if (f.convertTo != null) {
          status = 'Squeezing ${f.sourceName}';
          notifyListeners();
          try {
            final exe = await _ensureEngine(settings());
            await SdRun.convert(
              exe,
              source: file,
              out: target,
              type: f.convertTo!,
            );
          } finally {
            status = null;
          }
          await file.delete();
        }
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
    final video = m is VideoModel;
    final dir = video
        ? ImageCatalog.videoFor(settings())
        : ImageCatalog.dirFor(settings());
    final kept = {
      for (final other
          in video ? ImageCatalog.videoModels : ImageCatalog.models)
        if (other.id != m.id && ImageCatalog.installed(dir, other))
          for (final f in other.files) f.fileName,
    };
    // An own video file shares the VAE and text encoder of Wan 2.2 5B.
    for (final f in m.own ? m.files.take(1) : m.files) {
      if (kept.contains(f.fileName)) continue;
      final file = ImageCatalog.fileIn(dir, f);
      if (await file.exists()) await file.delete();
    }
    notifyListeners();
  }
}
