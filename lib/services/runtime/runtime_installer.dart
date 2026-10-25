import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'download.dart';

/// Gets a `llama-server` binary onto the machine.
///
/// Release builds can ship it next to the app (`<app>/runtime/`). Otherwise it
/// is downloaded once from the pinned llama.cpp release into the app-support
/// directory. The GPU build is picked per platform: Vulkan on Linux and
/// Windows (NVIDIA, AMD and Intel), Metal on macOS.
class RuntimeInstaller {
  RuntimeInstaller(this.supportDir, {http.Client? client})
    : _http = client ?? http.Client();

  /// llama.cpp release the app is tested against. Bump deliberately.
  static const pinnedTag = 'b11400';

  final Directory supportDir;
  final http.Client _http;

  static String get exeName =>
      Platform.isWindows ? 'llama-server.exe' : 'llama-server';

  Directory get installDir =>
      Directory(p.join(supportDir.path, 'runtime', pinnedTag));

  /// Path of a usable binary, or null if it still needs installing.
  Future<String?> find() async {
    final bundled = File(
      p.join(p.dirname(Platform.resolvedExecutable), 'runtime', exeName),
    );
    if (await bundled.exists()) return bundled.path;
    return _findIn(installDir);
  }

  /// Downloads and unpacks the runtime if needed; returns the binary path.
  Future<String> ensureInstalled({DownloadProgress? onProgress}) async {
    final existing = await find();
    if (existing != null) return existing;

    final assets = await _releaseAssets();
    final picks = pickAssets(
      assets.keys,
      os: Platform.operatingSystem,
      arm: _isArm64(),
    );
    if (picks.isEmpty) {
      throw RuntimeInstallException(
        'No llama.cpp build for ${Platform.operatingSystem} in $pinnedTag.',
      );
    }

    final tmp = Directory(p.join(supportDir.path, 'runtime', '.download'));
    await tmp.create(recursive: true);
    final staging = Directory('${installDir.path}.partial');
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

    if (await installDir.exists()) await installDir.delete(recursive: true);
    await staging.rename(installDir.path);
    final exe = await _findIn(installDir);
    if (exe == null) {
      throw RuntimeInstallException('$exeName missing from the download.');
    }
    if (!Platform.isWindows) {
      // Archives don't always keep the executable bit.
      await Process.run('chmod', ['+x', exe]);
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
  }) {
    final list = names.where((n) => !n.startsWith('cudart')).toList();
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
        final vulkan = find(r'bin-win-vulkan-x64\.zip$');
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
