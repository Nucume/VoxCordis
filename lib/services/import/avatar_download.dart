import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/desk/pictures.dart';
import 'import_temp.dart';
import 'imported_character.dart';

/// Fetches the picture an imported character links to. Only called after
/// the human presses Download next to the address, and only takes an HTTPS
/// image: redirects must stay on HTTPS, the size is capped, and the bytes
/// must be a PNG, JPEG or WebP whatever the server calls them.
class AvatarDownload {
  AvatarDownload({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const maxBytes = 15 * 1024 * 1024;
  static const _maxRedirects = 3;
  static const _timeout = Duration(seconds: 30);

  /// Saves the picture to a temporary file and returns it; the setup's
  /// finish copies it into the companion folder as its avatar.
  Future<File> fetch(Uri url) async {
    var current = url;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (current.scheme != 'https' || current.host.isEmpty) {
        throw const ImportException(
          'The picture is not on a secure (https) address, so it was not '
          'downloaded.',
        );
      }
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['Accept'] = 'image/png,image/jpeg,image/webp';
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
          'The picture could not be downloaded (${response.statusCode}).',
        );
      }
      if ((response.contentLength ?? 0) > maxBytes) {
        await response.stream.drain<void>();
        throw const ImportException('The picture is too big.');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          throw const ImportException('The picture is too big.');
        }
      }
      final ext = Pictures.imageExtensionOf(bytes);
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
    throw const ImportException('The picture address redirects too often.');
  }

  void close() => _client.close();
}
