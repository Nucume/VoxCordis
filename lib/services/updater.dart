import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'release_signature.dart';
import 'system/package_install.dart';
import 'runtime/download.dart' show sha256Digest, verifySha256;
import 'system/posix_native.dart';

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
  Updater({
    http.Client? client,
    Map<String, String>? environment,
    String? packageType,
    @visibleForTesting
    Future<void> Function(String program, List<String> args)? start,
    @visibleForTesting void Function()? quit,
    @visibleForTesting this.failedStartPause = const Duration(seconds: 8),
  }) : _client = client ?? http.Client(),
       _env = environment ?? Platform.environment,
       packageType =
           packageType ?? (environment == null ? installedPackageType() : null),
       _start = start ?? _startDetached,
       _quit = quit ?? (() => exit(0));

  final http.Client _client;
  final Map<String, String> _env;
  final Future<void> Function(String program, List<String> args) _start;
  final void Function() _quit;

  /// How long the error shows when the new version didn't start after the
  /// database was closed, before the app quits all the same.
  final Duration failedStartPause;

  static Future<void> _startDetached(String program, List<String> args) =>
      Process.start(program, args, mode: ProcessStartMode.detached);

  /// The most [install]'s atExit may take: a slow close never stops the
  /// app from quitting.
  static const atExitLimit = Duration(seconds: 10);

  /// "deb" or "rpm" when a package manager installed this copy. Such a copy
  /// never updates itself; the apt or dnf repository delivers new versions.
  final String? packageType;

  /// What updates a package install, or null for other installs.
  String? get packageUpdateCommand => switch (packageType) {
    'deb' => 'sudo apt update && sudo apt install --only-upgrade voxcordis',
    'rpm' => 'sudo dnf upgrade --refresh voxcordis',
    _ => null,
  };

  /// Where the apt and dnf repositories (and how to add them) are described.
  static String get packageRepoPage {
    final parts = updateRepo.split('/');
    return 'https://${parts.first.toLowerCase()}.github.io/${parts.last}/repo/';
  }

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

  /// Deletes installers that earlier updates left in the temporary folder.
  /// The app quits to let the installer run, so nothing else ever removes
  /// them. One still running can't be deleted; it goes at the next start.
  static Future<void> deleteLeftoverInstallers({Directory? temp}) async {
    if (temp == null && !Platform.isWindows) return;
    final dir = temp ?? Directory.systemTemp;
    final ours = RegExp(r'^VoxCordis-[\w.+-]+-setup\.exe$');
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || !ours.hasMatch(e.uri.pathSegments.last)) continue;
        try {
          await e.delete();
        } on FileSystemException {
          // In use, or already gone.
        }
      }
    } on FileSystemException {
      // No temporary folder to look in.
    }
  }

  /// Downloads [info] and hands over to it. On success this never returns:
  /// [beforeExit] runs (stop the model server), the new version is put in
  /// place, [atExit] runs (close the database) and the app quits so the new
  /// version can take its place. When a step before [atExit] fails, the app
  /// keeps running, so [beforeExit] must not close what it still needs.
  ///
  /// The new AppImage starts only after [atExit]: Linux lets one copy of the
  /// app run, so a new copy started while this one is still open hands over
  /// to it and stops, and nothing is left running once this one quits. The
  /// Windows installer takes a while before it starts the app, so there
  /// [atExit] runs once the installer has started.
  Future<void> install(
    UpdateInfo info, {
    required Future<void> Function() beforeExit,
    Future<void> Function()? atExit,
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
        PosixNative.makeExecutable(target.path);
        // Replacing the file under a running AppImage is safe: the old one
        // stays mounted until this process exits.
        await target.rename(appImage);
        // The new version is in place: from here the app quits either way.
        await _closeForExit(atExit);
        try {
          await _start(appImage, []);
        } on Object catch (e) {
          // The database is closed, so this copy can't carry on. The new
          // version starts the next time the app is opened.
          error =
              'The new version is installed but did not start ($e). '
              'VoxCordis will close now: open it again to use the new version.';
          progress = null;
          // Still "installing", so the dialog keeps its buttons off: the
          // chats can't be used any more, and a second update must not start.
          _set(UpdateStatus.installing);
          await Future<void>.delayed(failedStartPause);
        }
      } else {
        // /update=1 makes the installer start the app again when done.
        await _start(target.path, [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/update=1',
        ]);
        await _closeForExit(atExit);
      }
      _quit();
    } catch (e) {
      // A half-finished or rejected download is no use to anyone.
      try {
        final image = _appImage;
        final partial = image == null ? null : File('$image.update');
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        // Leave it.
      }
      if (_appImage == null) deleteLeftoverInstallers().ignore();
      error = 'The update failed: $e';
      progress = null;
      _set(UpdateStatus.failed);
    }
  }

  /// Runs [atExit] for at most [atExitLimit]; a failure doesn't stop the
  /// app from quitting.
  static Future<void> _closeForExit(Future<void> Function()? atExit) async {
    try {
      await atExit?.call().timeout(atExitLimit);
    } on Object {
      // The new version is on its way: quit all the same.
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
