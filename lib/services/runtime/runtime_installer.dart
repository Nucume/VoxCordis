import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../release_signature.dart';
import '../updater.dart' show updateRepo;
import 'download.dart';
import '../system/posix_native.dart';

/// Gets a `llama-server` binary onto the machine.
///
/// Release builds can ship it next to the app (`<app>/runtime/`). Otherwise it
/// is downloaded once from the pinned llama.cpp release into the app-support
/// directory. The GPU build is picked per platform: Vulkan on Linux and
/// Windows (NVIDIA, AMD and Intel), Metal on macOS.
class RuntimeInstaller {
  RuntimeInstaller(
    this.supportDir, {
    http.Client? client,
    Future<int?> Function()? nvidiaDriver,
  }) : _http = client ?? http.Client(),
       _nvidiaDriver = nvidiaDriver ?? detectNvidiaDriver;

  /// llama.cpp release the app is tested against. Bump deliberately.
  static const pinnedTag = 'b11400';

  final Directory supportDir;
  final http.Client _http;
  final Future<int?> Function() _nvidiaDriver;

  /// Told why the CUDA build was not used, so Settings → Logs can say.
  void Function(String message)? note;

  /// Oldest NVIDIA driver (major version) that runs CUDA 12.x builds. With an
  /// older one the CUDA backend would fail to load and llama.cpp would quietly
  /// fall back to the CPU, which is far slower than Vulkan.
  static const minCudaDriver = 528;

  /// Same for the Linux CUDA 12.4 build (the Windows number is higher only
  /// because Windows drivers are numbered differently).
  static const minCudaDriverLinux = 525;

  /// Major version of the installed NVIDIA driver, or null without one.
  static Future<int?> detectNvidiaDriver() async {
    try {
      final r = await Process.run('nvidia-smi', [
        '--query-gpu=driver_version',
        '--format=csv,noheader',
      ]);
      if (r.exitCode != 0) return null;
      return parseDriverMajor(r.stdout as String);
    } on ProcessException {
      return null;
    }
  }

  /// `551.61` (one line per card) -> 551.
  static int? parseDriverMajor(String out) {
    for (final line in out.split('\n')) {
      final m = RegExp(r'^\s*(\d+)\.').firstMatch(line);
      if (m != null) return int.parse(m.group(1)!);
    }
    return null;
  }

  /// Set when the CUDA build would not start, or hung, this run. It stays
  /// off until the app is started again, even when the marker below runs
  /// out.
  bool _cudaFailed = false;

  Future<bool> _wantCuda() async {
    if (Platform.isMacOS || _cudaFailed) return false;
    // Tried again a day later, so a release that gains a CUDA build, or a
    // network that was down, gets another go.
    final marker = File(_noCudaMarker);
    if (await marker.exists() &&
        DateTime.now().difference(await marker.lastModified()) <
            const Duration(days: 1)) {
      return false;
    }
    final v = await _nvidiaDriver();
    return v != null &&
        v >= (Platform.isWindows ? minCudaDriver : minCudaDriverLinux);
  }

  /// Written when no CUDA build could be had for this system, so the Vulkan
  /// install is used without looking again every launch.
  String get _noCudaMarker =>
      p.join(supportDir.path, 'runtime', '$pinnedTag.no-cuda');

  /// The CUDA `llama-server` the release workflow builds for Linux and
  /// attaches to the app's own release (llama.cpp publishes none). It is
  /// installed only when the release key signed it, like an update.
  static String get linuxCudaAsset =>
      'llama-server-cuda-$pinnedTag-linux-x64.tar.gz';

  Future<String?> _installLinuxCuda({DownloadProgress? onProgress}) async {
    try {
      if (!updateRepo.contains('/')) {
        note?.call('CUDA build skipped: no release repository is set.');
        return null;
      }
      final res = await _http.get(
        Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'},
      );
      if (res.statusCode != 200) {
        note?.call(
          'CUDA build skipped: GitHub answered HTTP ${res.statusCode} for the latest release of $updateRepo.',
        );
        return null;
      }
      final assets = (jsonDecode(res.body) as Map)['assets'] as List;
      Map? file;
      Map? sig;
      for (final a in assets.cast<Map>()) {
        if (a['name'] == linuxCudaAsset) file = a;
        if (a['name'] == '$linuxCudaAsset.sig') sig = a;
      }
      final sha = sha256Digest(file?['digest']);
      if (file == null || sig == null || sha == null) {
        note?.call(
          'CUDA build skipped: the latest release of $updateRepo has no signed $linuxCudaAsset yet.',
        );
        return null;
      }

      final sigRes = await _http.get(
        Uri.parse(sig['browser_download_url'] as String),
      );
      if (sigRes.statusCode != 200 ||
          !await ReleaseSignature.verify(sha, sigRes.bodyBytes)) {
        note?.call(
          'CUDA build skipped: its signature did not check out (HTTP ${sigRes.statusCode}).',
        );
        return null;
      }
      final tmp = Directory(p.join(supportDir.path, 'runtime', '.download'));
      await tmp.create(recursive: true);
      final archive = File(p.join(tmp.path, linuxCudaAsset));
      await downloadFile(
        _http,
        Uri.parse(file['browser_download_url'] as String),
        archive,
        onProgress: onProgress,
      );
      await verifySha256(archive, sha);
      final staging = Directory('${cudaInstallDir.path}.partial');
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      await extractFileToDisk(archive.path, staging.path);
      await archive.delete();
      if (await cudaInstallDir.exists()) {
        await cudaInstallDir.delete(recursive: true);
      }
      await staging.rename(cudaInstallDir.path);
      final exe = await _findIn(cudaInstallDir);
      if (exe == null) {
        note?.call('CUDA build skipped: llama-server was not in the download.');
      } else {
        PosixNative.makeExecutable(exe);
        note?.call('Using the CUDA build of llama-server.');
      }
      return exe;
    } on Object catch (e) {
      // Offline, no such file yet, bad signature: Vulkan it is.
      note?.call('CUDA build skipped: $e');
      return null;
    }
  }

  /// Whether [binary] is the CUDA build.
  bool isCuda(String binary) => p.isWithin(cudaInstallDir.path, binary);

  /// The CUDA build would not start but the other one did: use that from
  /// now on (for the rest of this run, and for a day after, then CUDA is
  /// tried again, as a newer release may have fixed it).
  Future<void> giveUpOnCuda(String why) async {
    _cudaFailed = true;
    note?.call('The CUDA llama-server did not start, so Vulkan is used: $why');
    final marker = File(_noCudaMarker);
    await marker.create(recursive: true);
    await marker.setLastModified(DateTime.now());
  }

  /// The CUDA build took too long to load a model: use the other one for
  /// the rest of this run only. No marker is written, as the model may just
  /// be too big, so CUDA gets another go at the next start.
  void skipCudaThisRun() {
    _cudaFailed = true;
    note?.call(
      'The CUDA llama-server took too long to load the model, so Vulkan is '
      'used for the rest of this run.',
    );
  }

  Directory get cudaInstallDir =>
      Directory(p.join(supportDir.path, 'runtime', '$pinnedTag-cuda'));

  static String get exeName =>
      Platform.isWindows ? 'llama-server.exe' : 'llama-server';

  Directory get installDir =>
      Directory(p.join(supportDir.path, 'runtime', pinnedTag));

  /// Path of a usable binary, or null if it still needs installing. Without
  /// [cuda] it is never the CUDA build.
  Future<String?> find({bool cuda = true}) async {
    final bundled = File(
      p.join(p.dirname(Platform.resolvedExecutable), 'runtime', exeName),
    );
    if (await bundled.exists()) return bundled.path;
    // An NVIDIA card gets the CUDA build, which is quicker than Vulkan; a
    // Vulkan install from before then counts as missing so it is upgraded.
    if (cuda && await _wantCuda()) return _findIn(cudaInstallDir);
    return _findIn(installDir);
  }

  Future<String>? _installing;
  bool? _installingCuda;

  /// Everyone waiting on [_installing] who wants to see its progress.
  final _listeners = <DownloadProgress>[];

  /// Downloads and unpacks the runtime if needed; returns the binary path.
  /// Without [cuda] it is never the CUDA build.
  Future<String> ensureInstalled({
    DownloadProgress? onProgress,
    bool cuda = true,
  }) async {
    final existing = await find(cuda: cuda);
    if (existing != null) return existing;

    final wantCuda = cuda && await _wantCuda();
    // One install at a time, as they share the download folder: a second
    // caller for the same build waits for the first one's and sees its
    // progress too.
    if (_installing case final running?) {
      if (_installingCuda == wantCuda) {
        if (onProgress != null) _listeners.add(onProgress);
        return running;
      }
      try {
        await running;
      } catch (_) {
        // Its caller says what went wrong.
      }
      return ensureInstalled(onProgress: onProgress, cuda: cuda);
    }
    _installingCuda = wantCuda;
    if (onProgress != null) _listeners.add(onProgress);
    return _installing =
        _install(wantCuda, (received, total) {
          for (final listener in List.of(_listeners)) {
            listener(received, total);
          }
        }).whenComplete(() {
          _installing = null;
          _installingCuda = null;
          _listeners.clear();
        });
  }

  Future<String> _install(bool wantCuda, DownloadProgress? onProgress) async {
    if (wantCuda && Platform.isLinux) {
      final exe = await _installLinuxCuda(onProgress: onProgress);
      if (exe != null) return exe;
      await File(_noCudaMarker).create(recursive: true);
      await File(_noCudaMarker).setLastModified(DateTime.now());
      note?.call('Using the Vulkan build of llama-server instead.');
      final vulkan = await _findIn(installDir);
      if (vulkan != null) return vulkan;
    }
    final assets = await _releaseAssets();
    final picks = pickAssets(
      assets.keys,
      os: Platform.operatingSystem,
      arm: _isArm64(),
      cuda: wantCuda,
    );
    final cuda = wantCuda && picks.any((n) => n.contains('cuda'));
    if (wantCuda && !cuda && Platform.isWindows) {
      await File(_noCudaMarker).create(recursive: true);
      await File(_noCudaMarker).setLastModified(DateTime.now());
    }
    final target = cuda ? cudaInstallDir : installDir;
    if (picks.isEmpty) {
      throw RuntimeInstallException(
        'No llama.cpp build for ${Platform.operatingSystem} in $pinnedTag.',
      );
    }

    final tmp = Directory(p.join(supportDir.path, 'runtime', '.download'));
    await tmp.create(recursive: true);
    final staging = Directory('${target.path}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    for (final name in picks) {
      final file = File(p.join(tmp.path, name));
      final asset = assets[name]!;
      // The binary runs with the human's rights: never one GitHub can't
      // vouch for.
      if (asset.sha256 == null) {
        throw RuntimeInstallException(
          'GitHub lists no checksum for $name, so it was not installed.',
        );
      }
      await downloadFile(
        _http,
        Uri.parse(asset.url),
        file,
        onProgress: onProgress,
      );
      await verifySha256(file, asset.sha256!);
      await extractFileToDisk(file.path, staging.path);
      await file.delete();
    }

    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    final exe = await _findIn(target);
    if (exe == null) {
      throw RuntimeInstallException('$exeName missing from the download.');
    }
    if (!Platform.isWindows) {
      // Archives don't always keep the executable bit.
      PosixNative.makeExecutable(exe);
    }
    return exe;
  }

  Future<Map<String, ({String url, String? sha256})>> _releaseAssets() async {
    final res = await _http.get(
      Uri.parse(
        'https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$pinnedTag',
      ),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (res.statusCode != 200) {
      throw RuntimeInstallException(
        'Could not reach GitHub to fetch the runtime (HTTP ${res.statusCode}).',
      );
    }
    final assets = (jsonDecode(res.body) as Map)['assets'] as List;
    return {
      for (final a in assets.cast<Map>())
        a['name'] as String: (
          url: a['browser_download_url'] as String,
          sha256: sha256Digest(a['digest']),
        ),
    };
  }

  /// Chooses which release archives to install. Windows GPU archives hold
  /// only the backend DLL, so they come on top of the CPU archive.
  static List<String> pickAssets(
    Iterable<String> names, {
    required String os,
    required bool arm,
    bool cuda = false,
  }) {
    final list = names.toList();
    String? find(String pattern) {
      final re = RegExp(pattern);
      for (final n in list) {
        if (re.hasMatch(n)) return n;
      }
      return null;
    }

    switch (os) {
      case 'linux':
        final pick =
            find(r'bin-ubuntu-vulkan-x64\.(tar\.gz|zip)$') ??
            find(r'bin-ubuntu-x64\.(tar\.gz|zip)$');
        return [?pick];
      case 'macos':
        final pick = find(
          arm
              ? r'bin-macos-arm64\.(tar\.gz|zip)$'
              : r'bin-macos-x64\.(tar\.gz|zip)$',
        );
        return [?pick];
      case 'windows':
        final cpu = find(r'bin-win-cpu-x64\.zip$');
        if (cuda) {
          // CUDA 12.x only: 13 needs a newer driver than most people have.
          // The runtime DLLs ship in a separate archive of the same version.
          final build = find(r'^llama-.*bin-win-cuda-12\.\d+-x64\.zip$');
          final version = build == null
              ? null
              : RegExp(r'cuda-(12\.\d+)').firstMatch(build)!.group(1);
          final rt = version == null
              ? null
              : find('^cudart-.*cuda-${RegExp.escape(version)}-x64\\.zip\$');
          if (build != null && rt != null) return [?cpu, build, rt];
        }
        final vulkan = find(r'^llama-.*bin-win-vulkan-x64\.zip$');
        return [?cpu, ?vulkan];
    }
    return const [];
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

class RuntimeInstallException implements Exception {
  RuntimeInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}
