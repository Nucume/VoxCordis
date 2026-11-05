import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../release_signature.dart';
import '../updater.dart' show updateRepo;
import 'download.dart';

/// Gets a build the app's own release workflow makes and attaches to the
/// latest release (the CUDA llama-server and sd-cli for Linux, which their
/// projects don't publish). It is unpacked into [into] only when the
/// release key signed it, like an update; otherwise [note] is told why and
/// false comes back, so the caller uses another build.
Future<bool> installSignedReleaseAsset(
  http.Client client, {
  required String asset,
  required Directory into,
  required Directory downloads,
  DownloadProgress? onProgress,
  void Function(String message)? note,
  String what = 'CUDA build',
}) async {
  try {
    if (!updateRepo.contains('/')) {
      note?.call('$what skipped: no release repository is set.');
      return false;
    }
    final res = await client.get(
      Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (res.statusCode != 200) {
      note?.call(
        '$what skipped: GitHub answered HTTP ${res.statusCode} for the latest release of $updateRepo.',
      );
      return false;
    }
    final assets = (jsonDecode(res.body) as Map)['assets'] as List;
    Map? file;
    Map? sig;
    for (final a in assets.cast<Map>()) {
      if (a['name'] == asset) file = a;
      if (a['name'] == '$asset.sig') sig = a;
    }
    final sha = sha256Digest(file?['digest']);
    if (file == null || sig == null || sha == null) {
      note?.call(
        '$what skipped: the latest release of $updateRepo has no signed $asset yet.',
      );
      return false;
    }

    final sigRes = await client.get(
      Uri.parse(sig['browser_download_url'] as String),
    );
    if (sigRes.statusCode != 200 ||
        !await ReleaseSignature.verify(sha, sigRes.bodyBytes)) {
      note?.call(
        '$what skipped: its signature did not check out (HTTP ${sigRes.statusCode}).',
      );
      return false;
    }
    await downloads.create(recursive: true);
    final archive = File(p.join(downloads.path, asset));
    await downloadFile(
      client,
      Uri.parse(file['browser_download_url'] as String),
      archive,
      onProgress: onProgress,
    );
    await verifySha256(archive, sha);
    final staging = Directory('${into.path}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    await extractFileToDisk(archive.path, staging.path);
    await archive.delete();
    if (await into.exists()) await into.delete(recursive: true);
    await staging.rename(into.path);
    return true;
  } on Object catch (e) {
    // Offline, no such file yet, bad signature: the other build it is.
    note?.call('$what skipped: $e');
    return false;
  }
}
