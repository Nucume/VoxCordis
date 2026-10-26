import '../../data/desk/pictures.dart';
import '../../data/desk/shared_files.dart';
import '../../data/picture_notes.dart';
import '../../services/sight.dart';

/// Turns the picture and file lines in the chat history into what the
/// model reads. Only the [recent] latest messages with pictures send them
/// (or have Eyes look at them), and only the latest with files carry their
/// text: older ones are named, with what was seen in them, so a long chat
/// doesn't send every picture and file again with each message.
class PromptAttachments {
  PromptAttachments({
    required this.folder,
    required this.mode,
    required this.notes,
    required this.fileChars,
    required this.pictureUrl,
    this.look,
    this.recent = 2,
  });

  /// The companion folder the paths are in.
  final String folder;
  final SightMode mode;
  final PictureNotes notes;

  /// Most characters of shared text sent with one message.
  final int fileChars;

  /// The picture at a path as a `data:` URL, or null when it is missing.
  final Future<String?> Function(String relative) pictureUrl;

  /// Has Eyes describe the picture at a path, which the human shared with
  /// the words given; null when it couldn't. Only for [SightMode.eyes].
  final Future<String?> Function(String relative, String said)? look;
  final int recent;

  /// Whether the last [expand] sent any picture itself.
  bool sentPictures = false;

  /// The paths of pictures Eyes couldn't look at in the last [expand].
  final unseen = <String>[];

  /// [turns] (from [alternatingHistory]) with their attachments expanded.
  /// A message that sends pictures gets OpenAI-style content parts.
  Future<List<Map<String, Object?>>> expand(
    List<Map<String, Object?>> turns,
  ) async {
    sentPictures = false;
    unseen.clear();
    final out = [...turns];
    var pictureTurns = recent, fileTurns = recent;
    for (var i = out.length - 1; i >= 0; i--) {
      final turn = out[i];
      final content = turn['content'];
      if (turn['role'] != 'user' || content is! String) continue;
      final pictures = Pictures.inText(content);
      final files = SharedFiles.inText(content);
      if (pictures.isEmpty && files.isEmpty) continue;
      final freshPictures = pictures.isNotEmpty && pictureTurns-- > 0;
      final freshFiles = files.isNotEmpty && fileTurns-- > 0;
      final said = SharedFiles.withoutMarkers(content);
      final images = <Map<String, Object?>>[];
      final lines = <String>[];
      for (final line in content.split('\n')) {
        if (Pictures.inText(line) case [final rel]) {
          lines.add(await _picture(rel, freshPictures, said, images));
        } else if (SharedFiles.inText(line) case [final rel]) {
          lines.add(
            await _file(rel, freshFiles ? fileChars ~/ files.length : 0),
          );
        } else {
          lines.add(line);
        }
      }
      final text = lines.join('\n');
      out[i] = {
        'role': 'user',
        'content': images.isEmpty
            ? text
            : [
                {'type': 'text', 'text': text},
                ...images,
              ],
      };
      sentPictures = sentPictures || images.isNotEmpty;
    }
    return out;
  }

  Future<String> _picture(
    String rel,
    bool fresh,
    String said,
    List<Map<String, Object?>> images,
  ) async {
    switch (mode) {
      case SightMode.native when fresh:
        final url = await pictureUrl(rel);
        if (url == null) return '[image: $rel (the file is gone)]';
        images.add({
          'type': 'image_url',
          'image_url': {'url': url},
        });
        return '[image: $rel]';
      case SightMode.native:
        final note = await notes.get(rel);
        return note == null
            ? '[image: $rel, which you saw earlier]'
            : '[image: $rel, which you saw earlier: $note]';
      case SightMode.eyes:
        var note = await notes.get(rel);
        if (note == null && fresh) note = await look?.call(rel, said);
        if (note != null) return '[image: $rel. You see: $note]';
        if (fresh) unseen.add(rel);
        return fresh
            ? '[image: $rel. You couldn\'t look at it this time.]'
            : '[image: $rel, shared earlier]';
      case SightMode.none:
        return '[image: $rel. You can\'t see pictures.]';
    }
  }

  /// The file's text when [maxChars] is above 0, else just its name.
  Future<String> _file(String rel, int maxChars) async {
    if (maxChars <= 0) {
      return '[file: $rel, shared earlier; read_file reads it again]';
    }
    final read = await SharedFiles.read(folder, rel, maxChars: maxChars);
    if (read == null) return '[file: $rel (the file is gone)]';
    var fence = '```';
    while (read.text.contains(fence)) {
      fence += '`';
    }
    return '[file: $rel]\n$fence\n${read.text}\n$fence'
        '${read.cut ? '\n(Only the start of the file; read_file reads the '
                  'rest.)' : ''}';
  }
}
