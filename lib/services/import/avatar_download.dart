import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/desk/pictures.dart';
import '../avatar_video.dart';
import 'import_temp.dart';
import 'imported_character.dart';

/// Fetches the picture or video an imported character links to. Only
/// called after the human presses Download next to the address, and only
/// over HTTPS: redirects must stay on HTTPS, the size is capped, and the
/// bytes must be a PNG, JPEG or WebP (or an MP4 or WebM video) whatever
/// the server calls them.
class AvatarDownload {
  AvatarDownload({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const maxBytes = 15 * 1024 * 1024;
  static const _maxRedirects = 3;
  static const _timeout = Duration(seconds: 30);

  /// Saves the picture to a temporary file and returns it; the setup's
  /// finish copies it into the companion folder as its avatar.
  Future<File> fetch(Uri url) async {
    final bytes = await _get(
      url,
      accept: 'image/png,image/jpeg,image/webp',
      limit: maxBytes,
      what: 'picture',
    );
    final ext = Pictures.imageExtensionOf(bytes);
    if (ext == null && isVideo(bytes)) {
      throw const ImportException(
        'That address is a video, not a picture. Soulkyn shows some '
        'avatars as short videos; use a screenshot of it as the portrait '
        'instead.',
      );
    }
    if (ext == null) {
      throw const ImportException(
        'That address did not give back a picture (PNG, JPEG or WebP).',
      );
    }
    final dir = await ImportTemp.create();
    final file = File(p.join(dir.path, 'avatar.$ext'));
    await file.writeAsBytes(bytes);
    return file;
  }

  static const maxVideoBytes = 60 * 1024 * 1024;

  /// Saves a portrait set to a temporary folder: `avatar.<ext>` and its
  /// video `avatar.mp4`, and the 18+ versions `avatar-nsfw.*`, whichever
  /// [set] has. Without a picture, [still] (the frame the import took) or
  /// the video's first frame stands in. Returns the main picture; the rest
  /// sits beside it (see [Pictures.setAvatarSet]). A part that fails is
  /// left out, unless nothing is left.
  Future<File> fetchSet(
    AvatarSet set, {
    File? still,
    Future<File?> Function(File video) stillFrom = AvatarVideo.stillFrom,
  }) async {
    final dir = await ImportTemp.create();
    ImportException? failed;
    Future<File?> part(Uri? url, String stem, {required bool video}) async {
      if (url == null) return null;
      try {
        return video
            ? await _saveVideo(url, dir, stem)
            : await _savePicture(url, dir, stem);
      } on ImportException catch (e) {
        failed ??= e;
        return null;
      }
    }

    var main = await part(set.still, 'avatar', video: false);
    final clip = await part(set.video, 'avatar', video: true);
    var nsfw = await part(set.nsfwStill, 'avatar-nsfw', video: false);
    final nsfwClip = await part(set.nsfwVideo, 'avatar-nsfw', video: true);
    if (main == null && clip != null) {
      main = still != null && await still.exists()
          ? await still.copy(
              p.join(
                dir.path,
                'avatar${p.extension(still.path).toLowerCase()}',
              ),
            )
          : await stillFrom(clip);
    }
    if (nsfw == null && nsfwClip != null) nsfw = await stillFrom(nsfwClip);
    if (main == null && nsfw != null) {
      // Only an 18+ version: it is the portrait.
      main = await nsfw.rename(
        p.join(dir.path, 'avatar${p.extension(nsfw.path)}'),
      );
      await nsfwClip?.rename(
        p.join(dir.path, 'avatar${p.extension(nsfwClip.path)}'),
      );
    }
    if (main != null) return main;
    await dir.delete(recursive: true);
    if (clip != null || nsfwClip != null) {
      throw const ImportException(
        'The video can\'t play on this computer, so it was not kept. On '
        'Linux, video portraits need libmpv (the "libmpv2" or "mpv-libs" '
        'package).',
      );
    }
    throw failed ??
        const ImportException('The avatar could not be downloaded.');
  }

  Future<File> _savePicture(Uri url, Directory dir, String stem) async {
    final bytes = await _get(
      url,
      accept: 'image/png,image/jpeg,image/webp',
      limit: maxBytes,
      what: 'picture',
    );
    final ext = Pictures.imageExtensionOf(bytes);
    if (ext == null) {
      throw const ImportException(
        'That address did not give back a picture (PNG, JPEG or WebP).',
      );
    }
    return File(p.join(dir.path, '$stem.$ext')).writeAsBytes(bytes);
  }

  Future<File> _saveVideo(Uri url, Directory dir, String stem) async {
    final bytes = await _get(
      url,
      accept: 'video/mp4,video/webm',
      limit: maxVideoBytes,
      what: 'video',
    );
    if (!isVideo(bytes)) {
      throw const ImportException(
        'That address did not give back a video (MP4 or WebM).',
      );
    }
    final ext = _at(bytes, 4, 'ftyp'.codeUnits) ? 'mp4' : 'webm';
    return File(p.join(dir.path, '$stem.$ext')).writeAsBytes(bytes);
  }

  /// The body of [url], following up to three HTTPS redirects, at most
  /// [limit] bytes.
  Future<List<int>> _get(
    Uri url, {
    required String accept,
    required int limit,
    required String what,
  }) async {
    var current = url;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (current.scheme != 'https' || current.host.isEmpty) {
        throw ImportException(
          'The $what is not on a secure (https) address, so it was not '
          'downloaded.',
        );
      }
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['Accept'] = accept;
      final response = await _client.send(request).timeout(_timeout);
      if (response.isRedirect || (response.statusCode ~/ 100 == 3)) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) break;
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw ImportException(
          'The $what could not be downloaded (${response.statusCode}).',
        );
      }
      if ((response.contentLength ?? 0) > limit) {
        await response.stream.drain<void>();
        throw ImportException('The $what is too big.');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > limit) {
          throw ImportException('The $what is too big.');
        }
      }
      return bytes;
    }
    throw ImportException('The $what address redirects too often.');
  }

  static bool _at(List<int> head, int i, List<int> bytes) {
    if (head.length < i + bytes.length) return false;
    for (var j = 0; j < bytes.length; j++) {
      if (head[i + j] != bytes[j]) return false;
    }
    return true;
  }

  /// Whether [head] starts like an MP4/MOV (`ftyp` box) or WebM/MKV file.
  static bool isVideo(List<int> head) =>
      _at(head, 4, 'ftyp'.codeUnits) || _at(head, 0, [0x1A, 0x45, 0xDF, 0xA3]);

  /// Saves a still frame of a video avatar, as the browser window drew it
  /// (`data:image/jpeg;base64,…`), to a temporary file. Null when [dataUrl]
  /// is not a PNG, JPEG or WebP picture within the size cap.
  static Future<File?> saveFrame(String dataUrl) async {
    final m = RegExp(
      r'^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/=\s]+)$',
    ).firstMatch(dataUrl);
    if (m == null || m.group(2)!.length > maxBytes * 4 ~/ 3 + 4) return null;
    final List<int> bytes;
    try {
      bytes = base64.decode(m.group(2)!.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return null;
    }
    final ext = Pictures.imageExtensionOf(bytes);
    if (ext == null || bytes.length > maxBytes) return null;
    final dir = await ImportTemp.create();
    final file = File(p.join(dir.path, 'avatar.$ext'));
    await file.writeAsBytes(bytes);
    return file;
  }

  void close() => _client.close();
}
