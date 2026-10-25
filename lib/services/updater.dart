import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'release_signature.dart';
import 'runtime/download.dart' show sha256Digest, verifySha256;

/// The version this build was made as. The release workflow passes the tag
/// (e.g. `0.2.0`, or `0.1.0-dev.12` for test builds) with --dart-define.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.2.0-dev',
);

/// Where releases are published. It has to be readable without signing in,
/// so a private repository only works for its collaborators' tokens.
const updateRepo = String.fromEnvironment(
  'UPDATE_REPO',
  defaultValue: 'Nucume/VoxCordisPR',
);

/// GitHub's API; a local mock in tests.
const _api = String.fromEnvironment(
  'UPDATE_API',
  defaultValue: 'https://api.github.com',
);

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    this.assetUrl,
    this.assetSize,
    this.assetSha256,
    this.signatureUrl,
    this.signatureRequired = false,
  });

  final String version;
  final String notes;
  final String pageUrl;

  /// The file this install can update itself from; null when this kind of
  /// install (a dev build, macOS) has to be updated from [pageUrl] by hand.
  final String? assetUrl;
  final int? assetSize;

  /// The file's SHA-256 as GitHub lists it; the download must match.
  final String? assetSha256;

  /// The release key's signature of [assetSha256] ([ReleaseSignature]).
  final String? signatureUrl;

  /// Whether this build only installs signed files.
  final bool signatureRequired;

  /// Only a file with a checksum (and, once this build knows the release
  /// key, a signature) is installed in one step; anything else goes
  /// through [pageUrl].
  bool get canInstall =>
      assetUrl != null &&
      assetSha256 != null &&
      (!signatureRequired || signatureUrl != null);
}

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  failed,
}

/// Checks GitHub Releases for a newer version and installs it in one step:
/// the AppImage replaces itself, the Windows installer runs silently. Both
/// then start the new version.
class Updater extends ChangeNotifier {
  Updater({http.Client? client, Map<String, String>? environment})
    : _client = client ?? http.Client(),
      _env = environment ?? Platform.environment;

  final http.Client _client;
  final Map<String, String> _env;

  UpdateStatus status = UpdateStatus.idle;
  UpdateInfo? available;
  String? error;

  /// 0..1 while downloading.
  double? progress;

  void _set(UpdateStatus s) {
    status = s;
    notifyListeners();
  }

  /// Linux AppImage runtimes export the path of the running file.
  String? get _appImage => _env['APPIMAGE'];

  Future<UpdateInfo?> check() async {
    if (status == UpdateStatus.downloading ||
        status == UpdateStatus.installing) {
      return available;
    }
    error = null;
    _set(UpdateStatus.checking);
    try {
      final r = await _client
          .get(
            Uri.parse('$_api/repos/$updateRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        // No release yet, or the repository is private.
        available = null;
        _set(UpdateStatus.upToDate);
        return null;
      }
      if (r.statusCode != 200) throw 'GitHub answered ${r.statusCode}';
      available = parseRelease(
        jsonDecode(r.body) as Map<String, dynamic>,
        appImage: _appImage != null,
        windows: Platform.isWindows,
        requireSignature: ReleaseSignature.required,
      );
      if (available != null &&
          compareVersions(available!.version, appVersion) <= 0) {
        available = null;
      }
      _set(available == null ? UpdateStatus.upToDate : UpdateStatus.available);
      return available;
    } catch (e) {
      error = 'Could not check for updates: $e';
      _set(UpdateStatus.failed);
      return null;
    }
  }

  /// Downloads [info] and hands over to it. On success this never returns:
  /// [beforeExit] runs (stop the model server) and the app quits so the new
  /// version can take its place.
  Future<void> install(
    UpdateInfo info, {
    required Future<void> Function() beforeExit,
  }) async {
    if (!info.canInstall) return;
    error = null;
    progress = 0;
    _set(UpdateStatus.downloading);
    try {
      final appImage = _appImage;
      final target = appImage != null
          ? File('$appImage.update')
          : File(
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'VoxCordis-${info.version}-setup.exe',
            );
      await _download(info, target);
      _set(UpdateStatus.installing);
      await beforeExit();
      if (appImage != null) {
        await Process.run('chmod', ['755', target.path]);
        // Replacing the file under a running AppImage is safe: the old one
        // stays mounted until this process exits.
        await target.rename(appImage);
        await Process.start(appImage, [], mode: ProcessStartMode.detached);
      } else {
        // /update=1 makes the installer start the app again when done.
        await Process.start(target.path, [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/update=1',
        ], mode: ProcessStartMode.detached);
      }
      exit(0);
    } catch (e) {
      error = 'The update failed: $e';
      progress = null;
      _set(UpdateStatus.failed);
    }
  }

  Future<void> _download(UpdateInfo info, File target) async {
    final res = await _client.send(
      http.Request('GET', Uri.parse(info.assetUrl!)),
    );
    if (res.statusCode != 200) throw 'download answered ${res.statusCode}';
    final total = res.contentLength ?? info.assetSize;
    final sink = target.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total != null && total > 0) {
          progress = got / total;
          notifyListeners();
        }
      }
    } finally {
      await sink.close();
    }
    if (info.assetSize != null && got != info.assetSize) {
      await target.delete();
      throw 'the download was cut off ($got of ${info.assetSize} bytes)';
    }
    await verifySha256(target, info.assetSha256!);
    if (info.signatureRequired) {
      final sig = await _client
          .get(Uri.parse(info.signatureUrl!))
          .timeout(const Duration(seconds: 30));
      if (sig.statusCode != 200 ||
          sig.bodyBytes.length > 1024 ||
          !await ReleaseSignature.verify(info.assetSha256!, sig.bodyBytes)) {
        await target.delete();
        throw 'the download is not signed with the VoxCordis release key';
      }
    }
  }
}

/// Reads a GitHub release; picks the file this kind of install updates from.
@visibleForTesting
UpdateInfo? parseRelease(
  Map<String, dynamic> json, {
  required bool appImage,
  required bool windows,
  bool requireSignature = false,
}) {
  final tag = json['tag_name'] as String?;
  if (tag == null || json['draft'] == true) return null;
  Map<String, dynamic>? asset;
  final signatures = <String, String>{};
  for (final a in (json['assets'] as List? ?? const [])) {
    final name = (a as Map<String, dynamic>)['name'] as String;
    // Only files GitHub itself serves are run.
    final url = Uri.tryParse(a['browser_download_url'] as String? ?? '');
    if (url == null || url.scheme != 'https' || url.host != 'github.com') {
      continue;
    }
    if (name.endsWith('.sig')) {
      signatures[name.substring(0, name.length - 4)] = url.toString();
    } else if (asset == null &&
        ((appImage && name.endsWith('x86_64.AppImage')) ||
            (windows && name.endsWith('-windows-x64-setup.exe')))) {
      asset = a;
    }
  }
  return UpdateInfo(
    version: tag.startsWith('v') ? tag.substring(1) : tag,
    notes: (json['body'] as String? ?? '').trim(),
    pageUrl: json['html_url'] as String? ?? '',
    assetUrl: asset?['browser_download_url'] as String?,
    assetSize: asset?['size'] as int?,
    assetSha256: sha256Digest(asset?['digest']),
    signatureUrl: signatures[asset?['name']],
    signatureRequired: requireSignature,
  );
}

/// Semantic version order: 0.2.0 > 0.2.0-beta.1 > 0.1.9, and a test build
/// (0.1.0-dev.12) is older than the 0.1.0 release.
int compareVersions(String a, String b) {
  List<String> split(String v) => v.split('+').first.split('-');
  final pa = split(a), pb = split(b);
  final ca = pa.first.split('.'), cb = pb.first.split('.');
  for (var i = 0; i < 3; i++) {
    final x = int.tryParse(i < ca.length ? ca[i] : '0') ?? 0;
    final y = int.tryParse(i < cb.length ? cb[i] : '0') ?? 0;
    if (x != y) return x.compareTo(y);
  }
  final preA = pa.length > 1 ? pa.sublist(1).join('-') : null;
  final preB = pb.length > 1 ? pb.sublist(1).join('-') : null;
  if (preA == null || preB == null) {
    return preA == preB ? 0 : (preA == null ? 1 : -1);
  }
  final sa = preA.split('.'), sb = preB.split('.');
  for (var i = 0; i < sa.length && i < sb.length; i++) {
    final x = int.tryParse(sa[i]), y = int.tryParse(sb[i]);
    final c = (x != null && y != null)
        ? x.compareTo(y)
        : sa[i].compareTo(sb[i]);
    if (c != 0) return c;
  }
  return sa.length.compareTo(sb.length);
}
