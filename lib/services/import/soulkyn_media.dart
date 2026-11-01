import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/desk/pictures.dart';
import 'avatar_download.dart';

/// One picture or video from a Soulkyn character's gallery.
class SoulkynMedia {
  const SoulkynMedia({
    required this.id,
    required this.url,
    this.video = false,
    this.nsfw = false,
    this.poster,
  });

  /// Soulkyn's id for the file, which names the saved copy, so pressing
  /// the button again only fetches what is new.
  final String id;
  final Uri url;
  final bool video;
  final bool nsfw;

  /// A small still of a video, shown on its tile in the gallery.
  final Uri? poster;

  static const files = 'rub.soulkyn.io';

  static Uri _file(String id, [String ext = '']) =>
      Uri.https(files, '/$id$ext');

  /// Soulkyn's 400 px wide still of a picture.
  static Uri _thumb(String id) =>
      Uri.https(files, '/$id/scale_ratio~400x1000@q~85.webp');

  /// The files in one page of a character's gallery as Soulkyn's own app
  /// loaded it: [kind] 'Images' (pictures, some with a moving version) or
  /// 'Videos'. Locked items are left out.
  static List<SoulkynMedia> fromApi(String kind, Object? data) {
    if (data is! List) return const [];
    String? id(Object? v) {
      final s = v is String ? safeId(v) : '';
      return s.length >= 8 ? s : null;
    }

    final out = <SoulkynMedia>[];
    for (final e in data) {
      if (e is! Map) continue;
      if (kind == 'Images') {
        if (e['IsLocked'] == true) continue;
        final pic = id(e['FWSUUID']) ?? id(e['ImageURL']);
        if (pic == null) continue;
        final nsfw = e['IsNSFW'] == true;
        out.add(SoulkynMedia(id: pic, url: _file(pic), nsfw: nsfw));
        final vid = id(e['VideoFwsUUID']);
        if (vid != null) {
          out.add(
            SoulkynMedia(
              id: vid,
              url: _file(vid, '.mp4'),
              video: true,
              nsfw: nsfw,
              poster: _thumb(pic),
            ),
          );
        }
      } else if (kind == 'Videos') {
        final vid = id(e['VideoFwsUUID']);
        if (vid == null) continue;
        final image = e['Image'];
        final still = image is Map ? id(image['FWSUUID']) : null;
        out.add(
          SoulkynMedia(
            id: vid,
            url: _file(vid, '.mp4'),
            video: true,
            nsfw: e['NSFW'] == true,
            poster: still == null ? null : _thumb(still),
          ),
        );
      }
    }
    return out;
  }

  /// [items] with each file once.
  static List<SoulkynMedia> unique(Iterable<SoulkynMedia> items) {
    final seen = <String>{};
    return [
      for (final m in items)
        if (seen.add('${m.id}:${m.video}')) m,
    ];
  }

  /// Only Soulkyn's file servers, over https.
  static bool allowed(Uri u) =>
      u.scheme == 'https' &&
      RegExp(r'(^|\.)soulkyn\.(io|com)$').hasMatch(u.host.toLowerCase());

  /// [id] with anything but letters, digits, `-` and `_` taken out, so it
  /// can't climb out of the folder.
  static String safeId(String id) {
    final s = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return s.length > 64 ? s.substring(0, 64) : s;
  }
}

/// How far [SoulkynMediaDownload.saveAll] has got.
class SoulkynMediaProgress {
  const SoulkynMediaProgress({
    required this.total,
    this.saved = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  final int total;

  /// New files written.
  final int saved;

  /// Already there from an earlier download.
  final int skipped;
  final int failed;

  int get done => saved + skipped + failed;

  SoulkynMediaProgress copyWith({int? saved, int? skipped, int? failed}) =>
      SoulkynMediaProgress(
        total: total,
        saved: saved ?? this.saved,
        skipped: skipped ?? this.skipped,
        failed: failed ?? this.failed,
      );
}

/// Saves a Soulkyn character's pictures and videos into the companion's
/// `images/` folder as `soulkyn-<id>.<ext>`. Each file must come from
/// Soulkyn over https, stay under a size cap, and start like a picture
/// (PNG, JPEG, WebP) or a video (MP4, WebM), whatever the server calls it.
/// It is written to a `.part` file first, so a cancelled or broken download
/// never leaves half a picture in the gallery.
class SoulkynMediaDownload {
  SoulkynMediaDownload({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  bool _cancelled = false;

  static const prefix = 'soulkyn-';
  static const maxPictureBytes = 40 << 20;
  static const maxVideoBytes = 400 << 20;
  static const _parallel = 3;
  static const _maxRedirects = 3;
  static const _timeout = Duration(seconds: 60);

  /// Stops after the files already on their way.
  void cancel() => _cancelled = true;

  /// Where video posters go: a hidden folder inside `images/`, so the
  /// gallery doesn't show them as pictures of their own.
  static const postersFolder = '.posters';

  /// The saved copy of [m] in [dir], if there is one already.
  static File? existing(Directory dir, SoulkynMedia m) =>
      _find(dir, '$prefix${m.id}', m.video);

  /// The poster saved for the video [file], if there is one.
  static File? posterFor(File file) => _find(
    Directory(p.join(p.dirname(file.path), postersFolder)),
    p.basenameWithoutExtension(file.path),
    false,
  );

  static File? _find(Directory dir, String base, bool video) {
    for (final ext in video ? videoExtensions : Pictures.extensions) {
      final f = File(p.join(dir.path, '$base.$ext'));
      if (f.existsSync()) return f;
    }
    return null;
  }

  static const videoExtensions = ['mp4', 'webm'];

  Future<SoulkynMediaProgress> saveAll(
    List<SoulkynMedia> items,
    Directory dir, {
    void Function(SoulkynMediaProgress)? onProgress,
  }) async {
    await dir.create(recursive: true);
    var progress = SoulkynMediaProgress(total: items.length);
    onProgress?.call(progress);
    var next = 0;
    Future<void> worker() async {
      while (!_cancelled && next < items.length) {
        final m = items[next++];
        if (existing(dir, m) != null) {
          progress = progress.copyWith(skipped: progress.skipped + 1);
        } else {
          try {
            await _save(m.url, dir, '$prefix${m.id}', video: m.video);
            progress = progress.copyWith(saved: progress.saved + 1);
          } on Object {
            progress = progress.copyWith(failed: progress.failed + 1);
          }
        }
        final poster = m.poster;
        if (m.video && poster != null && !_cancelled) {
          final posters = Directory(p.join(dir.path, postersFolder));
          if (_find(posters, '$prefix${m.id}', false) == null) {
            try {
              await posters.create(recursive: true);
              await _save(poster, posters, '$prefix${m.id}', video: false);
            } on Object {
              // The tile shows a plain play sign instead.
            }
          }
        }
        onProgress?.call(progress);
      }
    }

    await Future.wait([for (var i = 0; i < _parallel; i++) worker()]);
    return progress;
  }

  Future<File> _save(
    Uri url,
    Directory dir,
    String base, {
    required bool video,
  }) async {
    var current = url;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (!SoulkynMedia.allowed(current)) {
        throw const HttpException('Not a Soulkyn https address');
      }
      final request = http.Request('GET', current)..followRedirects = false;
      final response = await _client.send(request).timeout(_timeout);
      if (response.statusCode ~/ 100 == 3) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) break;
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw HttpException('HTTP ${response.statusCode}');
      }
      final cap = video ? maxVideoBytes : maxPictureBytes;
      if ((response.contentLength ?? 0) > cap) {
        await response.stream.drain<void>();
        throw const HttpException('Too big');
      }
      return _write(dir, base, response.stream, cap, video: video);
    }
    throw const HttpException('Too many redirects');
  }

  Future<File> _write(
    Directory dir,
    String base,
    Stream<List<int>> stream,
    int cap, {
    required bool video,
  }) async {
    final part = File(p.join(dir.path, '.$base.part'));
    final sink = part.openWrite();
    final head = <int>[];
    String? ext;
    var size = 0;
    try {
      await for (final chunk in stream.timeout(_timeout)) {
        if (_cancelled) throw const HttpException('Cancelled');
        size += chunk.length;
        if (size > cap) throw const HttpException('Too big');
        if (ext == null) {
          head.addAll(chunk.take(16 - head.length));
          if (head.length >= 16) {
            ext = kindOf(head, video: video);
            if (ext == null) {
              throw const HttpException('Not a picture or video');
            }
          }
        }
        sink.add(chunk);
      }
      await sink.close();
      ext ??= kindOf(head, video: video);
      if (ext == null) throw const HttpException('Not a picture or video');
      return await part.rename(p.join(dir.path, '$base.$ext'));
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// The extension the file's first bytes call for: a picture's, or for a
  /// video 'mp4' or 'webm'. Null when [head] is neither, or not what the
  /// page said it was.
  static String? kindOf(List<int> head, {required bool video}) {
    if (!video) return Pictures.imageExtensionOf(head);
    if (!AvatarDownload.isVideo(head)) return null;
    return head.length > 3 && head[0] == 0x1A ? 'webm' : 'mp4';
  }

  void close() => _client.close();
}
