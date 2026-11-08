import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../release_signature.dart';
import '../updater.dart' show updateRepo;
import 'download.dart';

/// How [installSignedReleaseAsset] went.
enum SignedAssetResult {
  /// Unpacked and ready.
  installed,

  /// No recent release carries it yet (or no release repository is set):
  /// looking again soon won't help.
  notPublished,

  /// GitHub refused or the network failed part way: worth another try
  /// soon, once a rate limit or a bad connection has passed.
  failed,
}

/// Where the signed file was found: its download address, the address of
/// its `.sig`, and the SHA-256 GitHub lists for it (null when it was found
/// without the API, so the hash is worked out from the download instead).
typedef _Found = ({String url, String sigUrl, String? sha});

/// Gets a build the app's own release workflow makes and attaches to its
/// releases (the CUDA llama-server and sd-cli for Linux, which their
/// projects don't publish), from the newest release that has it: the
/// latest one, or an older one or a pre-release when the latest lacks it.
///
/// The release list comes from GitHub's API, which allows only 60 calls an
/// hour to apps that aren't signed in and answers 403 past that (or to a
/// shared address that used them up). Then the public releases feed, which
/// has no such limit, gives the recent tags instead, and each tag's
/// download address is tried directly.
///
/// It is unpacked into [into] only when the release key signed it, like an
/// update; otherwise [note] is told why and the caller uses another build.
Future<SignedAssetResult> installSignedReleaseAsset(
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
      return SignedAssetResult.notPublished;
    }
    final (found, why) = await _findSigned(client, updateRepo, asset);
    if (found == null) {
      note?.call('$what skipped: $why');
      return why == null || why.startsWith('no recent release')
          ? SignedAssetResult.notPublished
          : SignedAssetResult.failed;
    }

    final sigRes = await client.get(Uri.parse(found.sigUrl), headers: _headers);
    if (sigRes.statusCode != 200) {
      note?.call(
        '$what skipped: GitHub answered HTTP ${sigRes.statusCode} '
        'for ${found.sigUrl}.',
      );
      return SignedAssetResult.failed;
    }
    // Checked before the big download when GitHub listed the hash.
    if (found.sha != null &&
        !await ReleaseSignature.verify(found.sha!, sigRes.bodyBytes)) {
      note?.call('$what skipped: its signature did not check out.');
      return SignedAssetResult.notPublished;
    }
    await downloads.create(recursive: true);
    final archive = File(p.join(downloads.path, asset));
    await downloadFile(
      client,
      Uri.parse(found.url),
      archive,
      onProgress: onProgress,
    );
    if (found.sha != null) {
      await verifySha256(archive, found.sha!);
    } else {
      final sha = (await sha256.bind(archive.openRead()).first).toString();
      if (!await ReleaseSignature.verify(sha, sigRes.bodyBytes)) {
        await archive.delete();
        note?.call('$what skipped: its signature did not check out.');
        return SignedAssetResult.notPublished;
      }
    }
    final staging = Directory('${into.path}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    await extractFileToDisk(archive.path, staging.path);
    await archive.delete();
    if (await into.exists()) await into.delete(recursive: true);
    await staging.rename(into.path);
    return SignedAssetResult.installed;
  } on Object catch (e) {
    // Offline, refused part way, damaged download: the other build it is.
    note?.call('$what skipped: $e');
    return SignedAssetResult.failed;
  }
}

/// GitHub asks every caller to say who it is; some of its servers refuse
/// requests that don't.
const _headers = {'User-Agent': 'VoxCordis'};

/// The newest signed [asset] of [repo], or why there is none.
Future<(_Found?, String?)> _findSigned(
  http.Client client,
  String repo,
  String asset,
) async {
  String apiWhy;
  try {
    final res = await client.get(
      Uri.parse('https://api.github.com/repos/$repo/releases?per_page=10'),
      headers: {
        ..._headers,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    );
    if (res.statusCode == 200) {
      final hit = newestSignedAsset(jsonDecode(res.body), asset);
      if (hit != null) {
        return (
          (
            url: hit.file['browser_download_url'] as String,
            sigUrl: hit.sig['browser_download_url'] as String,
            sha: hit.sha,
          ),
          null,
        );
      }
      return (null, 'no recent release of $repo has a signed $asset yet.');
    }
    apiWhy = _apiRefusal(res);
  } on Object catch (e) {
    apiWhy = 'the GitHub API could not be reached ($e)';
  }

  // The API said no: try the releases feed and the plain download links.
  List<String> tags;
  try {
    final feed = await client.get(
      Uri.parse('https://github.com/$repo/releases.atom'),
      headers: _headers,
    );
    if (feed.statusCode != 200) {
      return (
        null,
        '$apiWhy, and the releases feed answered HTTP ${feed.statusCode}.',
      );
    }
    tags = releaseTagsFromFeed(feed.body, repo).take(10).toList();
  } on Object catch (e) {
    return (null, '$apiWhy, and the releases feed failed ($e).');
  }
  for (final tag in tags) {
    final base = 'https://github.com/$repo/releases/download/$tag/$asset';
    try {
      final head = await client.head(Uri.parse('$base.sig'), headers: _headers);
      if (head.statusCode == 200) {
        return ((url: base, sigUrl: '$base.sig', sha: null), null);
      }
      if (head.statusCode != 404) {
        return (
          null,
          '$apiWhy, and GitHub answered HTTP ${head.statusCode} for $base.sig.',
        );
      }
    } on Object catch (e) {
      return (null, '$apiWhy, and $base.sig failed ($e).');
    }
  }
  return (null, 'no recent release of $repo has a signed $asset yet.');
}

/// Why the API refused, in words, for Settings → Logs.
String _apiRefusal(http.Response res) {
  final left = res.headers['x-ratelimit-remaining'];
  if ((res.statusCode == 403 || res.statusCode == 429) && left == '0') {
    final reset = int.tryParse(res.headers['x-ratelimit-reset'] ?? '');
    final at = reset == null
        ? ''
        : ' until ${DateTime.fromMillisecondsSinceEpoch(reset * 1000).toLocal().toIso8601String().substring(11, 16)}';
    return 'GitHub\'s API limit of 60 calls an hour is used up for this '
        'internet address$at (HTTP ${res.statusCode})';
  }
  return 'GitHub\'s API answered HTTP ${res.statusCode}';
}

/// The release tags in a GitHub releases Atom feed, newest first.
List<String> releaseTagsFromFeed(String atom, String repo) {
  final marker = RegExp(
    'href="https://github\\.com/${RegExp.escape(repo)}/releases/tag/([^"]+)"',
    caseSensitive: false,
  );
  final seen = <String>{};
  return [
    for (final m in marker.allMatches(atom))
      if (seen.add(Uri.decodeComponent(m.group(1)!)))
        Uri.decodeComponent(m.group(1)!),
  ];
}

/// The newest release in [releases] (GitHub's list, newest first) that
/// carries [asset] with its `.sig` and a SHA-256 digest; drafts are skipped.
({Map file, Map sig, String sha})? newestSignedAsset(
  Object? releases,
  String asset,
) {
  if (releases is! List) return null;
  for (final r in releases.whereType<Map>()) {
    if (r['draft'] == true || r['assets'] is! List) continue;
    Map? file;
    Map? sig;
    for (final a in (r['assets'] as List).whereType<Map>()) {
      if (a['name'] == asset) file = a;
      if (a['name'] == '$asset.sig') sig = a;
    }
    final sha = sha256Digest(file?['digest']);
    if (file != null && sig != null && sha != null) {
      return (file: file, sig: sig, sha: sha);
    }
  }
  return null;
}
