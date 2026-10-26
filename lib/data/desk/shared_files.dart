import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'pictures.dart';

/// What a file the human shares in the chat is.
enum SharedKind { picture, text }

/// Text files the human shares in the chat: notes, code, data. Each is
/// copied into the companion's `files/` folder and named in the message as
/// a line `[file: files/<name>]`; its text goes to the model with the
/// message.
class SharedFiles {
  static const folder = 'files';

  /// The biggest file shared; anything longer is cut when it is read anyway.
  static const maxBytes = 5 * 1024 * 1024;

  /// The biggest picture shared.
  static const maxPictureBytes = 30 * 1024 * 1024;

  static const textExtensions = [
    'txt',
    'md',
    'markdown',
    'json',
    'csv',
    'tsv',
    'log',
    'yaml',
    'yml',
    'toml',
    'ini',
    'cfg',
    'conf',
    'xml',
    'html',
    'htm',
    'css',
    'srt',
    'js',
    'ts',
    'dart',
    'py',
    'java',
    'kt',
    'swift',
    'c',
    'h',
    'cpp',
    'hpp',
    'cs',
    'go',
    'rs',
    'rb',
    'php',
    'lua',
    'sh',
    'bat',
    'ps1',
    'sql',
  ];

  static final _marker = RegExp(r'^\[file: ([^\]\n]+)\]$', multiLine: true);

  static String marker(String relative) => '[file: $relative]';

  /// The shared files named in a message, relative to the folder.
  static List<String> inText(String text) => [
    for (final m in _marker.allMatches(text)) m.group(1)!.trim(),
  ];

  /// The message without its file and picture lines.
  static String withoutMarkers(String text) =>
      Pictures.withoutMarkers(text.replaceAll(_marker, '')).trim();

  /// What [path] is, judged by its content: a picture, plain text, or
  /// null for anything the companion can't read (a PDF, a program).
  static Future<SharedKind?> kindOf(String path) async {
    final file = File(path);
    try {
      final size = await file.length();
      final head = <int>[];
      await for (final chunk in file.openRead(0, 8192)) {
        head.addAll(chunk);
      }
      if (Pictures.imageExtensionOf(head) != null) {
        return size <= maxPictureBytes ? SharedKind.picture : null;
      }
      if (size > maxBytes || !looksLikeText(head)) return null;
      final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
      // A text file without a known ending is still fine to read.
      return ext.isEmpty || textExtensions.contains(ext) || size < 1024 * 1024
          ? SharedKind.text
          : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Whether [head] reads as UTF-8 text: no NUL bytes and no broken
  /// characters, except where the sample may have cut one in half.
  static bool looksLikeText(List<int> head) {
    if (head.contains(0)) return false;
    try {
      utf8.decode(head);
      return true;
    } on FormatException {
      // The sample may end in the middle of a character.
      for (var cut = 1; cut <= 3 && cut < head.length; cut++) {
        try {
          utf8.decode(head.sublist(0, head.length - cut));
          return true;
        } on FormatException {
          continue;
        }
      }
      return false;
    }
  }

  /// Copies a file the human shares into `files/` and returns its path
  /// relative to [companionFolder], always with forward slashes.
  static Future<String> share(
    String companionFolder,
    String source,
    DateTime now,
  ) async {
    final dir = Directory(p.join(companionFolder, folder));
    await dir.create(recursive: true);
    final stamp = DateFormat('yyyy-MM-dd_HHmmss').format(now);
    final base = p.basenameWithoutExtension(source);
    final ext = p.extension(source).toLowerCase();
    var name = '$stamp-$base$ext';
    for (var n = 2; await File(p.join(dir.path, name)).exists(); n++) {
      name = '$stamp-$base-$n$ext';
    }
    await File(source).copy(p.join(dir.path, name));
    return '$folder/$name';
  }

  /// The shared file [relative] names, or null when it is not inside
  /// [companionFolder]: message text can come from the model.
  static File? fileIn(String companionFolder, String relative) {
    final root = p.normalize(p.absolute(companionFolder));
    final full = p.normalize(p.joinAll([root, ...relative.split('/')]));
    return p.isWithin(root, full) ? File(full) : null;
  }

  /// The text of a shared file, at most [maxChars] of it, and whether it
  /// was cut. Null when the file is gone.
  static Future<({String text, bool cut})?> read(
    String companionFolder,
    String relative, {
    required int maxChars,
  }) async {
    final file = fileIn(companionFolder, relative);
    if (file == null || !await file.exists()) return null;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    if (text.length <= maxChars) return (text: text, cut: false);
    return (text: text.substring(0, maxChars), cut: true);
  }
}
