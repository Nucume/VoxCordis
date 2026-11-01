import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// (bytes received, total bytes or null if unknown)
typedef DownloadProgress = void Function(int received, int? total);

/// Files at least this big are fetched over several connections at once.
const _parallelMin = 32 * 1024 * 1024;

/// Downloads [url] to [target] through a `.part` file, resuming a previous
/// partial download when the server supports ranges.
///
/// Big files come down as blocks over up to [connections] connections at the
/// same time, starting with 4 and adding more while the speed keeps rising, because one connection to a CDN (Hugging
/// Face, GitHub) rarely fills a fast line. Servers without range support get a single stream.
/// [onProgress] is called at most about ten times a second.
Future<File> downloadFile(
  http.Client client,
  Uri url,
  File target, {
  DownloadProgress? onProgress,
  bool Function()? isCancelled,
  int connections = 24,
}) async {
  final part = File('${target.path}.part');
  await target.parent.create(recursive: true);
  final state = File('${target.path}.part.segs');

  // A half-finished single-stream download keeps going single-stream.
  final legacy = await part.exists() && !await state.exists();
  if (connections > 1 && !legacy) {
    final total = await _rangedSize(client, url);
    if (total != null && total >= _parallelMin) {
      return _downloadParallel(
        client,
        url,
        target,
        part,
        state,
        total,
        connections,
        onProgress,
        isCancelled, //
      );
    }
  }
  return _downloadSingle(client, url, target, part, onProgress, isCancelled);
}

/// The file's size when the server answers byte-range requests, else null.
Future<int?> _rangedSize(http.Client client, Uri url) async {
  try {
    final req = http.Request('GET', url)..headers['Range'] = 'bytes=0-0';
    final res = await client.send(req);
    await res.stream.drain<void>();
    if (res.statusCode != 206) return null;
    final m = RegExp(
      r'/(\d+)\s*$',
    ).firstMatch(res.headers['content-range'] ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  } catch (_) {
    return null;
  }
}

class _Throttle {
  _Throttle(this.onProgress, this.total);
  final DownloadProgress? onProgress;
  final int? total;
  final _clock = Stopwatch()..start();
  int _lastMs = -1000;

  void call(int received, {bool force = false}) {
    if (onProgress == null) return;
    final now = _clock.elapsedMilliseconds;
    if (!force && now - _lastMs < 100) return;
    _lastMs = now;
    onProgress!(received, total);
  }
}

Future<File> _downloadParallel(
  http.Client client,
  Uri url,
  File target,
  File part,
  File state,
  int total,
  int maxConnections,
  DownloadProgress? onProgress,
  bool Function()? isCancelled,
) async {
  // Small blocks that any connection can pick up next, so the number of
  // connections can change while the file comes down.
  final block = (total ~/ 128).clamp(16 << 20, 64 << 20);
  final n = (total / block).ceil();
  int len(int i) => min(block, total - i * block);
  var done = List<int>.filled(n, 0);

  // Pick up a previous attempt only if it was cut the same way.
  var resumed = false;
  if (await state.exists() && await part.exists()) {
    try {
      final j = jsonDecode(await state.readAsString()) as Map;
      final d = (j['done'] as List).cast<int>();
      if (j['total'] == total &&
          j['block'] == block &&
          d.length == n &&
          await part.length() == total) {
        done = [for (var i = 0; i < n; i++) min(d[i], len(i))];
        resumed = true;
      }
    } catch (_) {}
  }
  if (!resumed) {
    final f = await part.open(mode: FileMode.write);
    await f.truncate(total);
    await f.close();
  }

  Future<void> save() => state.writeAsString(
    jsonEncode({'total': total, 'block': block, 'done': done}),
    flush: true,
  );
  await save();

  final progress = _Throttle(onProgress, total);
  var sum = done.fold(0, (a, b) => a + b);
  progress(sum, force: true);

  var next = 0; // blocks below this have been handed out
  final retry = <int>[]; // blocks whose request failed
  final failures = List<int>.filled(n, 0);
  Object? fatal;
  var active = 0;

  /// Takes the next unfinished block, or null when none are left.
  int? claim() {
    if (retry.isNotEmpty) return retry.removeLast();
    while (next < n) {
      final i = next++;
      if (done[i] < len(i)) return i;
    }
    return null;
  }

  Future<void> worker() async {
    active++;
    final raf = await part.open(mode: FileMode.append);
    try {
      while (fatal == null) {
        final i = claim();
        if (i == null) return;
        final start = i * block;
        try {
          final req = http.Request('GET', url)
            ..headers['Range'] =
                'bytes=${start + done[i]}-${start + len(i) - 1}';
          final res = await client.send(req);
          if (res.statusCode != 206) {
            throw HttpException('HTTP ${res.statusCode} for $url', uri: url);
          }
          await for (final chunk in res.stream) {
            if (isCancelled?.call() ?? false) throw const DownloadCancelled();
            final room = len(i) - done[i];
            final data = chunk.length > room ? chunk.sublist(0, room) : chunk;
            await raf.setPosition(start + done[i]);
            await raf.writeFrom(data);
            done[i] += data.length;
            sum += data.length;
            progress(sum);
          }
          if (done[i] < len(i)) throw const HttpException('Ended early');
        } on DownloadCancelled catch (e) {
          fatal = e;
          return;
        } catch (e) {
          if (++failures[i] > 4) {
            fatal = e;
            return;
          }
          await Future<void>.delayed(Duration(seconds: failures[i]));
          retry.add(i);
        }
      }
    } finally {
      active--;
      await raf.close();
    }
  }

  final workers = <Future<void>>[];
  void spawn(int count) {
    for (var k = 0; k < count && active + k < maxConnections; k++) {
      workers.add(worker());
    }
  }

  // Start with a few connections and add two at a time for as long as the
  // total speed keeps rising by at least 15%: a 100 Mbit line stays at
  // four, a 10 Gbit line climbs until it is full.
  const startWith = 4;
  spawn(startWith);
  var bestRate = 0.0;
  var growing = true;
  var lastSum = sum;
  final ticker = Timer.periodic(const Duration(seconds: 2), (t) {
    save();
    final rate = (sum - lastSum) / 2;
    lastSum = sum;
    if (!growing || fatal != null || next >= n) return;
    if (rate >= bestRate * 1.15) {
      bestRate = rate;
      if (active < maxConnections) spawn(2);
    } else {
      growing = false;
    }
  });
  try {
    // New workers join the list while we wait, so keep waiting until none
    // are left.
    var seen = 0;
    while (seen < workers.length) {
      await workers[seen++];
    }
  } finally {
    ticker.cancel();
    await save();
  }
  if (fatal != null) throw fatal!;
  progress(total, force: true);
  if (await target.exists()) await target.delete();
  await part.rename(target.path);
  if (await state.exists()) await state.delete();
  return target;
}

Future<File> _downloadSingle(
  http.Client client,
  Uri url,
  File target,
  File part,
  DownloadProgress? onProgress,
  bool Function()? isCancelled,
) async {
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
  final progress = _Throttle(onProgress, total);
  var received = have;
  try {
    await for (final chunk in res.stream) {
      if (isCancelled?.call() ?? false) {
        throw const DownloadCancelled();
      }
      sink.add(chunk);
      received += chunk.length;
      progress(received);
    }
  } finally {
    await sink.close();
  }
  progress(received, force: true);
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
