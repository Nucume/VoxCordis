import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../runtime/download.dart';
import 'image_catalog.dart';

/// Gets stable-diffusion.cpp's `sd-cli` onto the machine, the way
/// [RuntimeInstaller] gets llama-server: once, from a pinned release whose
/// files and checksums are written down here, so nothing else is ever run.
class SdInstaller {
  SdInstaller(this.supportDir, {http.Client? client})
    : _http = client ?? http.Client();

  /// The release VoxCordis is tested against. Bump deliberately, with the
  /// new checksums from its release page.
  static const pinnedTag = 'master-920-2f88688';
  static const _commit = '2f88688';

  /// Each build: its file on the release page and the SHA-256 listed there.
  static const builds = <String, ({String file, String sha256})>{
    'linux-vulkan': (
      file: 'sd-master-$_commit-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip',
      sha256:
          '81187de7eef5828816858de076c6d7efe4ee29e1536d22f86338960d5119c574',
    ),
    'linux-cpu': (
      file: 'sd-master-$_commit-bin-Linux-Ubuntu-24.04-x86_64.zip',
      sha256:
          '7367e4034a77a425aaa7d0795e02b6007329a58a893541c9fd6a4c79c196796b',
    ),
    'windows-vulkan': (
      file: 'sd-master-$_commit-bin-win-vulkan-x64.zip',
      sha256:
          '63e84439c20dde75487a933066318ae01353e9e80ee70e031acad48e857e1cb9',
    ),
    'windows-cpu': (
      file: 'sd-master-$_commit-bin-win-cpu-x64.zip',
      sha256:
          '10fc73b25bd97fb071c6bb6ba2a18e8811e6dd421c32bead98c18c84cd305d7f',
    ),
    'macos-arm64': (
      file: 'sd-master-$_commit-bin-Darwin-macOS-26.6.2-arm64.zip',
      sha256:
          '3f229ee34485e5c6b697c05702886fd86a66f386cdba73bf866f585f5d3223ad',
    ),
  };

  final Directory supportDir;
  final http.Client _http;

  static String get exeName => Platform.isWindows ? 'sd-cli.exe' : 'sd-cli';

  /// The build for this computer: Vulkan (NVIDIA, AMD and Intel cards)
  /// unless the graphics card is off, Metal on a Mac. Null where there is
  /// none (Intel Macs, ARM Linux and Windows).
  static String? buildFor({
    required String os,
    required bool arm,
    required bool gpu,
  }) => switch (os) {
    'linux' when !arm => gpu ? 'linux-vulkan' : 'linux-cpu',
    'windows' when !arm => gpu ? 'windows-vulkan' : 'windows-cpu',
    'macos' when arm => 'macos-arm64',
    _ => null,
  };

  static String? get _thisBuildGpu =>
      buildFor(os: Platform.operatingSystem, arm: _isArm64(), gpu: true);
  static String? get _thisBuildCpu =>
      buildFor(os: Platform.operatingSystem, arm: _isArm64(), gpu: false);

  static bool get supported => _thisBuildGpu != null;

  Directory installDir(String build) =>
      Directory(p.join(supportDir.path, 'draw', pinnedTag, build));

  /// The sd-cli to run, or null when it still needs installing.
  Future<String?> find({required bool gpu}) async {
    final build = gpu ? _thisBuildGpu : _thisBuildCpu;
    if (build == null) return null;
    return _findIn(installDir(build));
  }

  /// Downloads and unpacks sd-cli if needed; returns its path.
  Future<String> ensureInstalled({
    required bool gpu,
    DownloadProgress? onProgress,
  }) async {
    final existing = await find(gpu: gpu);
    if (existing != null) return existing;
    final build = gpu ? _thisBuildGpu : _thisBuildCpu;
    if (build == null) {
      throw SdException(
        'Drawing isn\'t available for this computer yet '
        '(${Platform.operatingSystem}).',
      );
    }
    final asset = builds[build]!;
    final dir = installDir(build);
    final zip = File(p.join(dir.parent.path, '.download', asset.file));
    await downloadFile(
      _http,
      Uri.parse(
        'https://github.com/leejet/stable-diffusion.cpp/releases/download/'
        '$pinnedTag/${asset.file}',
      ),
      zip,
      onProgress: onProgress,
    );
    await verifySha256(zip, asset.sha256);
    final staging = Directory('${dir.path}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    await extractFileToDisk(zip.path, staging.path);
    await zip.delete();
    if (await dir.exists()) await dir.delete(recursive: true);
    await staging.rename(dir.path);
    final exe = await _findIn(dir);
    if (exe == null) throw SdException('$exeName missing from the download.');
    if (!Platform.isWindows) {
      // Zip files don't keep the executable bit.
      await Process.run('chmod', ['+x', exe]);
    }
    return exe;
  }

  static Future<String?> _findIn(Directory dir) async {
    if (!await dir.exists()) return null;
    await for (final e in dir.list(recursive: true)) {
      if (e is File && p.basename(e.path) == exeName) return e.path;
    }
    return null;
  }

  static bool _isArm64() {
    final v = Platform.version.toLowerCase();
    return v.contains('arm64') || v.contains('aarch64');
  }
}

/// One picture to draw.
class DrawRequest {
  const DrawRequest({
    required this.model,
    required this.prompt,
    this.negative = '',
    this.shape = 'square',
    this.loras = const [],
    this.seed,
    this.width,
    this.height,
    this.steps,
    this.cfg,
  });

  final ImageModel model;
  final String prompt;
  final String negative;

  /// "square", "portrait" or "landscape".
  final String shape;

  /// LoRA names (file names without extension) with their weight.
  final List<({String name, double weight})> loras;
  final int? seed;

  /// Overrides for the model card's size, steps and guidance, from the
  /// advanced options of drawing by hand.
  final int? width;
  final int? height;
  final int? steps;
  final double? cfg;
}

/// Runs sd-cli for one picture.
class SdRun {
  /// The arguments for [r], with models in [modelsDir] and LoRAs in
  /// [lorasDir], written to [out].
  static List<String> args(
    DrawRequest r, {
    required Directory modelsDir,
    required Directory lorasDir,
    required File out,
    required int seed,
  }) {
    final m = r.model;
    final size = r.width != null && r.height != null
        ? (width: r.width!, height: r.height!)
        : m.sizeFor(r.shape);
    // LoRAs go in as <lora:name:weight> tags, which sd-cli reads from the
    // prompt; any the model wrote itself are dropped first, as they could
    // name a file anywhere on the computer.
    final prompt = [
      m.prefix,
      cleanPrompt(r.prompt),
      m.suffix,
      for (final l in r.loras) ' <lora:${l.name}:${l.weight}>',
    ].join();
    final negative = [
      cleanPrompt(r.negative),
      m.negative,
    ].where((t) => t.trim().isNotEmpty).join(', ');
    return [
      for (final f in m.files) ...[
        f.role.flag,
        ImageCatalog.fileIn(modelsDir, f).path,
      ],
      '-p', prompt,
      if (negative.isNotEmpty) ...['-n', negative],
      '--cfg-scale', '${r.cfg ?? m.cfg}',
      '--steps', '${r.steps ?? m.steps}',
      '--sampling-method', m.sampler,
      if (m.scheduler != null) ...['--scheduler', m.scheduler!],
      '-W', '${size.width}',
      '-H', '${size.height}',
      '-s', '$seed',
      // Decoding in tiles keeps the last step from running out of memory.
      '--vae-tiling',
      if (r.loras.isNotEmpty) ...['--lora-model-dir', lorasDir.path],
      '-o', out.path,
    ];
  }

  /// [text] without tags in angle brackets (LoRAs, embeddings) and
  /// without line breaks, at most 2000 characters.
  static String cleanPrompt(String text) {
    final t = text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[<>]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t.length > 2000 ? t.substring(0, 2000) : t;
  }

  static final _progress = RegExp(r'(\d+)/(\d+) - [\d.]+(s/it|it/s)');

  /// The step count in one line of sd-cli's output, like
  /// "|=====>    | 5/20 - 1.23s/it".
  static ({int step, int steps})? progressIn(String line) {
    final all = _progress.allMatches(line);
    if (all.isEmpty) return null;
    final m = all.last;
    final steps = int.parse(m[2]!);
    if (steps == 0) return null;
    return (step: int.parse(m[1]!), steps: steps);
  }

  /// Draws [r] into [out]. [onProgress] gets 0..1 through the sampling
  /// steps. [cancel] stops it when it completes.
  static Future<File> run(
    String exe,
    DrawRequest r, {
    required Directory modelsDir,
    required Directory lorasDir,
    required File out,
    required int seed,
    void Function(double fraction)? onProgress,
    Future<void>? cancel,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    await out.parent.create(recursive: true);
    final dir = File(exe).parent.path;
    final process = await Process.start(
      exe,
      args(r, modelsDir: modelsDir, lorasDir: lorasDir, out: out, seed: seed),
      workingDirectory: dir,
      environment: {
        // The libraries come in the same folder as sd-cli.
        if (Platform.isLinux)
          'LD_LIBRARY_PATH': [
            dir,
            ?Platform.environment['LD_LIBRARY_PATH'],
          ].join(':'),
        if (Platform.isMacOS) 'DYLD_LIBRARY_PATH': dir,
      },
    );
    final log = Queue<String>();
    void keep(String line) {
      if (line.trim().isEmpty) return;
      log.addLast(line);
      while (log.length > 30) {
        log.removeFirst();
      }
    }

    // Progress is redrawn on one line with \r.
    final outLines = process.stdout
        .transform(utf8.decoder)
        .expand((chunk) => chunk.split(RegExp('[\r\n]')))
        .listen((line) {
          final pr = progressIn(line);
          if (pr != null) {
            onProgress?.call(pr.step / pr.steps);
          } else {
            keep(line);
          }
        }, onError: (_) {});
    final errLines = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(keep, onError: (_) {});
    var cancelled = false;
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        process.kill();
      }),
    );
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw SdException('Drawing took too long and was stopped.');
    } finally {
      await outLines.cancel();
      await errLines.cancel();
    }
    if (cancelled) throw SdException('Drawing was stopped.');
    if (code != 0 || !await out.exists()) {
      final hint = log.lastWhere(
        (l) => RegExp(
          r'error|fail|out of memory',
          caseSensitive: false,
        ).hasMatch(l),
        orElse: () => log.isEmpty ? '' : log.last,
      );
      throw SdException(
        'The picture couldn\'t be drawn${hint.isEmpty ? '' : ' (${hint.trim()})'}.',
        output: log.join('\n'),
      );
    }
    return out;
  }
}

class SdException implements Exception {
  SdException(this.message, {this.output = ''});
  final String message;

  /// What sd-cli printed last, for Settings → Logs.
  final String output;
  @override
  String toString() => message;
}
