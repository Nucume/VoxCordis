import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../runtime/download.dart';
import '../runtime/runtime_installer.dart';
import '../runtime/signed_release_asset.dart';
import 'image_catalog.dart';
import '../system/posix_native.dart';

/// Gets stable-diffusion.cpp's `sd-cli` onto the machine, the way
/// [RuntimeInstaller] gets llama-server: once, from a pinned release whose
/// files and checksums are written down here, so nothing else is ever run.
/// An NVIDIA card gets a CUDA build, which draws faster than Vulkan: the
/// official one on Windows, and on Linux the one the app's release workflow
/// builds and signs (stable-diffusion.cpp publishes none).
class SdInstaller {
  SdInstaller(
    this.supportDir, {
    http.Client? client,
    Future<int?> Function()? nvidiaDriver,
  }) : _http = client ?? http.Client(),
       _nvidiaDriver = nvidiaDriver ?? RuntimeInstaller.detectNvidiaDriver;

  /// The release VoxCordis is tested against. Bump deliberately, with the
  /// new checksums from its release page (and SD_TAG in the public release
  /// workflow, which builds the Linux CUDA sd-cli from it).
  static const pinnedTag = 'master-920-2f88688';
  static const _commit = '2f88688';

  /// Each build: its files on the release page and the SHA-256 listed
  /// there. All of a build's files are unpacked into one folder.
  static const builds = <String, List<({String file, String sha256})>>{
    'linux-vulkan': [
      (
        file: 'sd-master-$_commit-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip',
        sha256:
            '81187de7eef5828816858de076c6d7efe4ee29e1536d22f86338960d5119c574',
      ),
    ],
    'linux-cpu': [
      (
        file: 'sd-master-$_commit-bin-Linux-Ubuntu-24.04-x86_64.zip',
        sha256:
            '7367e4034a77a425aaa7d0795e02b6007329a58a893541c9fd6a4c79c196796b',
      ),
    ],
    'windows-vulkan': [
      (
        file: 'sd-master-$_commit-bin-win-vulkan-x64.zip',
        sha256:
            '63e84439c20dde75487a933066318ae01353e9e80ee70e031acad48e857e1cb9',
      ),
    ],
    // The CUDA 12 build and the CUDA runtime it needs beside it.
    'windows-cuda': [
      (
        file: 'sd-master-$_commit-bin-win-cuda12-x64.zip',
        sha256:
            '479133a03d5c861ce77e70354dbbe75dd6e8d9955d1d1c7b6b1456b4571e3039',
      ),
      (
        file: 'cudart-sd-bin-win-cu12-x64.zip',
        sha256:
            'fe20366827d357c00797eebb58244dddab7fd9a348d70090c3871004c320f38d',
      ),
    ],
    'windows-cpu': [
      (
        file: 'sd-master-$_commit-bin-win-cpu-x64.zip',
        sha256:
            '10fc73b25bd97fb071c6bb6ba2a18e8811e6dd421c32bead98c18c84cd305d7f',
      ),
    ],
    'macos-arm64': [
      (
        file: 'sd-master-$_commit-bin-Darwin-macOS-26.6.2-arm64.zip',
        sha256:
            '3f229ee34485e5c6b697c05702886fd86a66f386cdba73bf866f585f5d3223ad',
      ),
    ],
  };

  /// The CUDA sd-cli the app's release workflow builds for Linux and
  /// attaches, signed, to the app's own release.
  static String get linuxCudaAsset => 'sd-cli-cuda-$pinnedTag-linux-x64.tar.gz';

  final Directory supportDir;
  final http.Client _http;
  final Future<int?> Function() _nvidiaDriver;

  /// Told which build draws and why CUDA wasn't used, for Settings → Logs.
  void Function(String message)? note;

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

  /// The CUDA build for this computer, where there is one.
  static String? cudaBuildFor({required String os, required bool arm}) =>
      switch (os) {
        'linux' when !arm => 'linux-cuda',
        'windows' when !arm => 'windows-cuda',
        _ => null,
      };

  static String? get _thisBuildGpu =>
      buildFor(os: Platform.operatingSystem, arm: _isArm64(), gpu: true);
  static String? get _thisBuildCpu =>
      buildFor(os: Platform.operatingSystem, arm: _isArm64(), gpu: false);
  static String? get _thisBuildCuda =>
      cudaBuildFor(os: Platform.operatingSystem, arm: _isArm64());

  static bool get supported => _thisBuildGpu != null;

  Directory installDir(String build) =>
      Directory(p.join(supportDir.path, 'draw', pinnedTag, build));

  /// Set when the CUDA build failed to start this run; off until restart.
  bool _cudaFailed = false;

  /// Written when CUDA couldn't be had or wouldn't start, so Vulkan is used
  /// without trying again for a day.
  File get _noCudaMarker =>
      File(p.join(supportDir.path, 'draw', '$pinnedTag.no-cuda'));

  Future<bool> _wantCuda() async {
    if (_cudaFailed || _thisBuildCuda == null) return false;
    final marker = _noCudaMarker;
    if (await marker.exists() &&
        DateTime.now().difference(await marker.lastModified()) <
            const Duration(days: 1)) {
      return false;
    }
    final v = await _nvidiaDriver();
    return v != null &&
        v >=
            (Platform.isWindows
                ? RuntimeInstaller.minCudaDriver
                : RuntimeInstaller.minCudaDriverLinux);
  }

  Future<void> _markNoCuda() async {
    await _noCudaMarker.create(recursive: true);
    await _noCudaMarker.setLastModified(DateTime.now());
  }

  /// Whether [exe] is the CUDA build.
  bool isCuda(String exe) {
    final build = _thisBuildCuda;
    return build != null && p.isWithin(installDir(build).path, exe);
  }

  /// The CUDA build wouldn't start a drawing: Vulkan from now on, for the
  /// rest of this run and a day after (then CUDA is tried again).
  Future<void> giveUpOnCuda(String why) async {
    _cudaFailed = true;
    note?.call('The CUDA sd-cli did not start, so Vulkan is used: $why');
    await _markNoCuda();
  }

  /// The sd-cli to run, or null when it still needs installing. With an
  /// NVIDIA card that is the CUDA build; a Vulkan install from before
  /// counts as missing, so it is upgraded.
  Future<String?> find({required bool gpu}) async {
    if (gpu && await _wantCuda()) return _findIn(installDir(_thisBuildCuda!));
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
    if (gpu && await _wantCuda()) {
      final exe = await _installCuda(_thisBuildCuda!, onProgress);
      if (exe != null) {
        note?.call('Drawing with the CUDA build of sd-cli.');
        return exe;
      }
      await _markNoCuda();
      note?.call('Drawing with the Vulkan build of sd-cli instead.');
      final vulkan = await find(gpu: gpu);
      if (vulkan != null) return vulkan;
    }
    final build = gpu ? _thisBuildGpu : _thisBuildCpu;
    if (build == null) {
      throw SdException(
        'Drawing isn\'t available for this computer yet '
        '(${Platform.operatingSystem}).',
      );
    }
    return _installBuild(build, onProgress);
  }

  /// The CUDA build, or null (with a note) when it can't be had.
  Future<String?> _installCuda(
    String build,
    DownloadProgress? onProgress,
  ) async {
    try {
      if (build == 'linux-cuda') {
        final ok = await installSignedReleaseAsset(
          _http,
          asset: linuxCudaAsset,
          into: installDir(build),
          downloads: Directory(p.join(supportDir.path, 'draw', '.download')),
          onProgress: onProgress,
          note: note,
          what: 'CUDA drawing',
        );
        if (!ok) return null;
        final exe = await _findIn(installDir(build));
        if (exe == null) {
          note?.call('CUDA drawing skipped: sd-cli was not in the download.');
          return null;
        }
        PosixNative.makeExecutable(exe);
        return exe;
      }
      return await _installBuild(build, onProgress);
    } on Object catch (e) {
      note?.call('CUDA drawing skipped: $e');
      return null;
    }
  }

  Future<String> _installBuild(
    String build,
    DownloadProgress? onProgress,
  ) async {
    final files = builds[build]!;
    final dir = installDir(build);
    final staging = Directory('${dir.path}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    for (final asset in files) {
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
      await extractFileToDisk(zip.path, staging.path);
      await zip.delete();
    }
    if (await dir.exists()) await dir.delete(recursive: true);
    await staging.rename(dir.path);
    final exe = await _findIn(dir);
    if (exe == null) throw SdException('$exeName missing from the download.');
    if (!Platform.isWindows) {
      // Zip files don't keep the executable bit.
      PosixNative.makeExecutable(exe);
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
    this.sampler,
    this.scheduler,
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

  /// sd-cli's `--sampling-method` and `--scheduler` in place of the model
  /// card's; see [SdRun.samplers] and [SdRun.schedulers].
  final String? sampler;
  final String? scheduler;
}

/// A picture to bring to life: the video model reads [image] as the first
/// frame and [prompt] as what happens next.
class AnimateRequest extends DrawRequest {
  AnimateRequest({
    required VideoModel super.model,
    required super.prompt,
    required this.image,
    this.frames = 49,
    super.negative,
    super.shape,
    super.seed,
    super.steps,
    super.cfg,
  });

  final File image;

  /// Frames in the clip; Wan needs 4n + 1.
  final int frames;

  VideoModel get video => model as VideoModel;
}

/// Runs sd-cli for one picture.
class SdRun {
  /// The sampling methods sd-cli knows, with a name to show.
  static const samplers = <String, String>{
    'euler': 'Euler',
    'euler_a': 'Euler a',
    'heun': 'Heun',
    'dpm2': 'DPM2',
    'dpm++2s_a': 'DPM++ 2S a',
    'dpm++2m': 'DPM++ 2M',
    'dpm++2mv2': 'DPM++ 2M v2',
    'dpm++2m_sde': 'DPM++ 2M SDE',
    'dpm++2m_sde_bt': 'DPM++ 2M SDE BT',
    'ipndm': 'iPNDM',
    'ipndm_v': 'iPNDM v',
    'lcm': 'LCM',
    'ddim_trailing': 'DDIM trailing',
    'tcd': 'TCD',
    'res_multistep': 'Res multistep',
    'res_2s': 'Res 2s',
    'er_sde': 'ER-SDE',
    'euler_cfg_pp': 'Euler CFG++',
    'euler_a_cfg_pp': 'Euler a CFG++',
    'euler_ge': 'Euler GE',
    'lms': 'LMS',
  };

  /// The schedulers sd-cli knows for pictures, with a name to show (the
  /// ones only for particular video models are left out).
  static const schedulers = <String, String>{
    'discrete': 'Normal',
    'karras': 'Karras',
    'exponential': 'Exponential',
    'sgm_uniform': 'SGM uniform',
    'simple': 'Simple',
    'beta': 'Beta',
    'kl_optimal': 'KL optimal',
    'smoothstep': 'Smoothstep',
    'ays': 'Align Your Steps',
    'gits': 'GITS',
    'bong_tangent': 'Bong tangent',
    'lcm': 'LCM',
  };

  /// [v] when it is one of [names], so a saved choice from an older or
  /// newer version can't reach sd-cli as an unknown flag value.
  static String? _known(String? v, Map<String, String> names) =>
      names.containsKey(v) ? v : null;

  /// The arguments for turning a picture into a clip, written to [out].
  static List<String> videoArgs(
    AnimateRequest r, {
    required Directory modelsDir,
    required File out,
    required int seed,
  }) {
    final m = r.video;
    final size = m.sizeFor(r.shape);
    final negative = [
      cleanPrompt(r.negative),
      m.negative,
    ].where((t) => t.trim().isNotEmpty).join(', ');
    return [
      '-M', 'vid_gen',
      for (final f in m.files)
        if (f.role != ImageFileRole.upscaler) ...[
          f.role.flag,
          ImageCatalog.fileIn(modelsDir, f).path,
        ],
      '-i', r.image.path,
      '-p', cleanPrompt(r.prompt, max: 8000),
      if (negative.isNotEmpty) ...['-n', negative],
      '--cfg-scale', '${r.cfg ?? m.cfg}',
      if (m.sigmas != null) ...[
        '--sigmas',
        m.sigmas!,
      ] else ...[
        '--steps',
        '${r.steps ?? m.steps}',
      ],
      '--sampling-method', m.sampler,
      if (m.flowShift != null) ...['--flow-shift', '${m.flowShift}'],
      // LTX makes the clip small, enlarges it x2 and refines it.
      ..._upscaleArgs(m, modelsDir),
      // The 14B models have a second expert for the first steps.
      if (m.highNoiseSteps != null) ...[
        '--high-noise-cfg-scale',
        '${r.cfg ?? m.cfg}',
        '--high-noise-sampling-method',
        m.sampler,
        '--high-noise-steps',
        '${m.highNoiseSteps}',
      ],
      '-W', '${size.width}',
      '-H', '${size.height}',
      '--video-frames', '${r.frames}',
      '--fps', '${m.fps}',
      '-s', '$seed',
      // Flash attention is needed on Vulkan to avoid scrambled output, and
      // the weights wait in the computer's memory. VAE tiling is left out:
      // for Wan it is ignored or corrupts the picture the clip starts from.
      '--diffusion-fa',
      '--offload-to-cpu',
      ...m.extraArgs,
      '-o', out.path,
    ];
  }

  static List<String> _upscaleArgs(VideoModel m, Directory modelsDir) {
    final up = m.files.where((f) => f.role == ImageFileRole.upscaler);
    if (up.isEmpty) return const [];
    return [
      '--hires-upscalers-dir',
      modelsDir.path,
      '--hires-upscaler',
      p.basenameWithoutExtension(up.first.fileName),
      '--hires',
      if (m.hiresSigmas != null) ...['--hires-sigmas', m.hiresSigmas!],
    ];
  }

  /// Squeezes [source] into [out] with `sd-cli -M convert`, as [type]
  /// ("q8_0").
  static Future<void> convert(
    String exe, {
    required File source,
    required File out,
    required String type,
  }) async {
    final dir = File(exe).parent.path;
    final tmp = File('${out.path}.part');
    final res = await Process.run(
      exe,
      ['-M', 'convert', '-m', source.path, '--type', type, '-o', tmp.path],
      workingDirectory: dir,
      environment: {
        if (Platform.isLinux)
          'LD_LIBRARY_PATH': [
            dir,
            ?Platform.environment['LD_LIBRARY_PATH'],
          ].join(':'),
        if (Platform.isMacOS) 'DYLD_LIBRARY_PATH': dir,
      },
    );
    if (res.exitCode != 0 || !await tmp.exists()) {
      if (await tmp.exists()) await tmp.delete();
      throw SdException(
        'Squeezing the text encoder failed (it needs about 30 GB of free '
        'memory). ${'${res.stderr}'.trim().split('\n').last}',
      );
    }
    await tmp.rename(out.path);
  }

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
      '--sampling-method', _known(r.sampler, samplers) ?? m.sampler,
      if (_known(r.scheduler, schedulers) ?? m.scheduler case final sch?) ...[
        '--scheduler',
        sch,
      ],
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
  /// without line breaks, at most [max] characters (2000 for pictures; clips
  /// pass more, since video models like long prompts).
  static String cleanPrompt(String text, {int max = 2000}) {
    final t = text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[<>]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t.length > max ? t.substring(0, max) : t;
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
    Duration? timeout,
    void Function(String line)? onLine,
  }) async {
    await out.parent.create(recursive: true);
    final dir = File(exe).parent.path;
    final clip = r is AnimateRequest;
    timeout ??= Duration(minutes: clip ? 120 : 30);
    // A missing part only shows up in sd-cli as "new_sd_ctx_t failed".
    final missing = [
      for (final f in r.model.files)
        if (!await ImageCatalog.fileIn(modelsDir, f).exists()) f.fileName,
    ];
    if (missing.isNotEmpty) {
      // An own finetune borrows these from a catalog model.
      final from = r.model.own
          ? ImageCatalog.allModels
                .where((m) => m.files.any((f) => missing.contains(f.fileName)))
                .map((m) => m.name)
                .toList()
          : const <String>[];
      throw SdException(
        from.isNotEmpty
            ? '${r.model.name} needs ${missing.join(' and ')}, which come '
                  'with ${from.join(' or ')}. Download one of those in '
                  'Settings → Images.'
            : '${r.model.name} is missing ${missing.join(', ')} in '
                  '${modelsDir.path}. Download it again in Settings → Images.',
      );
    }
    final argv = r is AnimateRequest
        ? videoArgs(r, modelsDir: modelsDir, out: out, seed: seed)
        : args(
            r,
            modelsDir: modelsDir,
            lorasDir: lorasDir,
            out: out,
            seed: seed,
          );
    final process = await Process.start(
      exe,
      argv,
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
    onLine?.call('$exe ${argv.join(' ')}');
    void keep(String line) {
      if (line.trim().isEmpty) return;
      onLine?.call(line);
      log.addLast(line);
      // Enough to reach back past a failed load to its reason.
      while (log.length > 60) {
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
      // Let the last lines through: when sd-cli stops early they say why.
      Future<void> drained(StreamSubscription<String> lines) =>
          lines.asFuture<void>().then((_) {}, onError: (_) {});
      await Future.wait([
        drained(outLines),
        drained(errLines),
      ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw SdException(
        '${clip ? 'The clip' : 'Drawing'} took too long and was stopped.',
      );
    } finally {
      await outLines.cancel();
      await errLines.cancel();
    }
    if (cancelled) throw SdException('Drawing was stopped.');
    if (code != 0 || !await out.exists()) {
      throw SdException(
        failureMessage(log.toList(), r.model, clip: clip),
        output: log.join('\n'),
      );
    }
    return out;
  }

  /// sd-cli's own line for "couldn't load the model", which says nothing
  /// about why; the reason is in the lines before it.
  static final _ctxFailed = RegExp(
    r'new_sd_ctx_t failed',
    caseSensitive: false,
  );

  static final _outOfMemory = RegExp(
    r'out ?of ?(device )?memory|ErrorOutOfDeviceMemory|failed to allocate|'
    r'alloc(ate)? .*buffer.* failed|memory allocation of .* failed|'
    r'cudaMalloc failed|not enough memory',
    caseSensitive: false,
  );
  static final _unknownModel = RegExp(
    r'get sd version from file failed|unknown model|'
    r'could ?n.t detect|unsupported model',
    caseSensitive: false,
  );
  static final _cantOpen = RegExp(
    r"init model loader from file failed: '([^']*)'|failed to open '([^']*)'",
    caseSensitive: false,
  );
  static final _badTensors = RegExp(
    r'wrong shape|load tensors from (model loader|file) failed|'
    r'invalid (gguf|safetensors)|unknown file format',
    caseSensitive: false,
  );
  static final _noGpu = RegExp(
    r'vulkan.*(no devices|not found)|vkCreateInstance failed|'
    r'ErrorInitializationFailed|ErrorIncompatibleDriver|'
    r'failed to initiali[sz]e .*backend',
    caseSensitive: false,
  );

  /// Whether sd-cli's [output] says its CUDA backend didn't start, rather
  /// than a model problem or running out of memory, which Vulkan wouldn't
  /// fix.
  static bool cudaWontStart(String output) =>
      _cudaBroken.hasMatch(output) && !_outOfMemory.hasMatch(output);

  /// What a CUDA build prints when it can't run here at all (a CUDA
  /// device's ordinary start-up lines don't count).
  static final _cudaBroken = RegExp(
    r'CUDA error|failed to initiali[sz]e CUDA|no CUDA-capable device|'
    r'CUDA driver version is insufficient|ggml_cuda_init: failed|'
    r'(libcudart|libcublas|cudart64|cublas64)\S* *:? *(cannot open|not found)|'
    r'error while loading shared libraries: lib(cudart|cublas|cuda)',
    caseSensitive: false,
  );

  /// A message saying why sd-cli stopped, from the last lines it printed
  /// ([lines]): the likely cause in plain words and what to do, rather
  /// than its last line ("new_sd_ctx_t failed" says only that the model
  /// didn't load).
  static String failureMessage(
    List<String> lines,
    ImageModel model, {
    bool clip = false,
  }) {
    final what = clip
        ? 'The clip couldn\'t be made'
        : 'The picture couldn\'t be drawn';
    bool any(RegExp re) => lines.any(re.hasMatch);
    final loadFailed = any(_ctxFailed);
    final name = model.name;
    if (any(_outOfMemory)) {
      return '$what: the graphics card ran out of memory loading $name. '
          'Close other programs using it (games, other AI apps), keep '
          '"Free the graphics card while drawing" on in Settings → Images, '
          'or pick a smaller model or size.';
    }
    if (any(_unknownModel)) {
      return '$what: the drawing engine doesn\'t recognise $name as a '
          'model it can run. ${model.own ? 'If it\'s your own file, it may '
                    'not be a whole checkpoint (SD 1.5, SDXL, Pony or '
                    'Illustrious): LoRAs belong in the loras folder, and '
                    'Flux-style models that come in pieces can\'t be added '
                    'as one file.' : 'Delete it and download it again in '
                    'Settings → Images.'}';
    }
    for (final l in lines.reversed) {
      final m = _cantOpen.firstMatch(l);
      if (m == null) continue;
      final path = m[1] ?? m[2] ?? '';
      return '$what: the drawing engine couldn\'t open '
          '${path.isEmpty ? 'a file of $name' : p.basename(path)}. It may '
          'be damaged or still in use; download $name again in Settings → '
          'Images.';
    }
    if (any(_badTensors)) {
      return '$what: $name\'s file doesn\'t look like what the drawing '
          'engine expected. It may be damaged or a kind it can\'t run; '
          '${model.own ? 'try another model' : 'download it again in '
                    'Settings → Images'}.';
    }
    if (any(_noGpu)) {
      return '$what: the graphics card didn\'t start for drawing (Vulkan). '
          'Updating the graphics driver usually fixes this; turning off '
          '"Use my graphics card" in Settings → Brain draws on the '
          'processor instead (much slower).';
    }
    // Nothing known: the last line that sounds like a reason, without
    // sd-cli's "[ERROR ] file.cpp:12 - " in front.
    String clean(String l) => l
        .replaceFirst(RegExp(r'^\s*\[\w+\s*\]\s*[\w.]+:\d+\s*-\s*'), '')
        .trim();
    final reasons = lines.where((l) => !_ctxFailed.hasMatch(l)).toList();
    final hint =
        reasons.where((l) => l.contains('[ERROR')).lastOrNull ??
        reasons
            .where(
              (l) => RegExp(r'error|fail', caseSensitive: false).hasMatch(l),
            )
            .lastOrNull;
    if (hint != null) return '$what (${clean(hint)}).';
    if (loadFailed) {
      return '$what: the drawing engine couldn\'t load $name and didn\'t '
          'say why. Settings → Logs → Drawing has everything it printed.';
    }
    final last = lines.isEmpty ? '' : clean(lines.last);
    return '$what${last.isEmpty ? '' : ' ($last)'}.';
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
