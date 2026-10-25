import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// (bytes received, total bytes or null if unknown)
typedef DownloadProgress = void Function(int received, int? total);

/// Downloads [url] to [target] through a `.part` file, resuming a previous
/// partial download when the server supports ranges.
Future<File> downloadFile(
  http.Client client,
  Uri url,
  File target, {
  DownloadProgress? onProgress,
  bool Function()? isCancelled,
}) async {
  final part = File('${target.path}.part');
  await target.parent.create(recursive: true);
  var have = await part.exists() ? await part.length() : 0;

  final req = http.Request('GET', url);
  if (have > 0) req.headers['Range'] = 'bytes=$have-';
  final res = await client.send(req);

  if (res.statusCode == 200) {
    have = 0; // server ignored the range; start over
  } else if (res.statusCode == 416) {
    // Already complete.
    await part.rename(target.path);
    return target;
  } else if (res.statusCode != 206) {
    throw HttpException('HTTP ${res.statusCode} for $url', uri: url);
  }

  final total = res.contentLength == null ? null : have + res.contentLength!;
  final sink = part.openWrite(
    mode: have > 0 ? FileMode.append : FileMode.write,
  );
  var received = have;
  try {
    await for (final chunk in res.stream) {
      if (isCancelled?.call() ?? false) {
        throw const DownloadCancelled();
      }
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
  } finally {
    await sink.close();
  }
  if (total != null && received != total) {
    throw HttpException('Download ended early ($received of $total bytes)');
  }
  if (await target.exists()) await target.delete();
  return part.rename(target.path);
}

/// The SHA-256 GitHub lists for a release file (`"digest": "sha256:…"`),
/// or null when it lists none (files uploaded before mid-2025).
String? sha256Digest(Object? digest) {
  if (digest is! String || !digest.startsWith('sha256:')) return null;
  final hex = digest.substring(7).toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
}

/// Deletes [file] and throws unless its SHA-256 is [expected] (hex).
Future<void> verifySha256(File file, String expected) async {
  final actual = (await sha256.bind(file.openRead()).first).toString();
  if (actual != expected.toLowerCase()) {
    await file.delete();
    throw HttpException(
      'The download of ${file.uri.pathSegments.last} is damaged or was '
      'changed on the way (its checksum does not match).',
    );
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}
