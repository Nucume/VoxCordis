import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/images/image_catalog.dart';
import '../../services/images/image_engine.dart';
import '../../services/images/picture_info.dart';
import '../../theme/app_theme.dart';
import '../images/draw_panel.dart';
import 'voces_widgets.dart';

/// The picture part of a world's or character's editor: its own colours
/// (shuffle for new ones), or a picture uploaded or drawn.
class VocesPictureField extends StatelessWidget {
  const VocesPictureField({
    super.key,
    required this.name,
    required this.seed,
    required this.file,
    required this.wide,
    required this.prompt,
    required this.drawingFolder,
    required this.onSeed,
    required this.onFile,
  });

  final String name;
  final int seed;

  /// The picture shown now, or null for the colours.
  final File? file;

  /// A world's wide picture rather than a character's portrait.
  final bool wide;

  /// What "Draw it" starts from, built from the editor's fields.
  final String Function() prompt;
  final String drawingFolder;
  final ValueChanged<int> onSeed;

  /// A new picture, or null to go back to the colours.
  final ValueChanged<File?> onFile;

  Future<void> _upload() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Pictures',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (f != null) onFile(File(f.path));
  }

  Future<void> _draw(BuildContext context) async {
    final f = await showDialog<File>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          VocesDrawDialog(prompt: prompt(), wide: wide, folder: drawingFolder),
    );
    if (f != null) onFile(f);
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.palette.textMuted);
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: wide ? 224 : 108,
        height: wide ? 126 : 144,
        child: VocesArt(
          key: ValueKey(file?.path),
          name: name,
          seed: seed,
          file: file,
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        preview,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (file == null)
                    OutlinedButton.icon(
                      onPressed: () => onSeed(VocesLibrary.newArt()),
                      icon: const Icon(Icons.shuffle_rounded, size: 18),
                      label: const Text('Shuffle colours'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _upload,
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('Upload'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _draw(context),
                    icon: const Icon(Icons.brush_rounded, size: 18),
                    label: const Text('Draw it'),
                  ),
                  if (file != null)
                    TextButton.icon(
                      onPressed: () => onFile(null),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Use colours instead'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                wide
                    ? 'A wide picture works best. It also sets the mood '
                          'behind the story.'
                    : 'Draw it starts from their looks and traits; you can '
                          'change the words first.',
                style: muted,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Deletes [file] when it is a drawn try still waiting to be kept (an
/// upload is the person's own file and stays).
void dropDrawn(VocesLibrary library, File? file) {
  if (file == null || !p.isWithin(library.drawingFolder, file.path)) return;
  unawaited(file.delete().then((_) {}, onError: (_) {}));
}

/// Makes the next look at [file] read it again: a new picture keeps the
/// old one's name.
Future<void> forgetPicture(File? file) async {
  if (file != null) await FileImage(file).evict();
}

/// What "Draw it" starts from for a world: the kind of picture, its kinds
/// and feel, and its line.
String worldPrompt({
  required List<String> tags,
  required String line,
  required String setting,
}) => _join([
  'scenery',
  'wide shot',
  'no humans',
  'detailed background',
  ...tags,
  line,
  _firstSentence(setting),
]);

/// What "Draw it" starts from for a character: a portrait and their
/// looks. Drawing models read tags, so their picture tags are used when
/// they have them; else a short bit of the Looks part. Traits and the
/// one-line say who they are, not how they look, so they stay out.
String characterPrompt({
  required String? pronouns,
  required List<String> looksTags,
  required List<SheetSection> sections,
}) {
  final who = (pronouns ?? '').toLowerCase();
  final looks = looksTags.isNotEmpty
      ? looksTags.join(', ')
      : _cut(looksText(sections), 300);
  return _join([
    'portrait',
    'upper body',
    'solo',
    if (who.startsWith('she')) '1girl' else if (who.startsWith('he')) '1boy',
    'looking at viewer',
    looks,
  ]);
}

/// The sheet's parts about how they look, as one text.
String looksText(List<SheetSection> sections) => [
  for (final s in sections)
    if (RegExp(
      r'look|appear|body|physic|outfit',
      caseSensitive: false,
    ).hasMatch(s.heading))
      s.text,
].join(' ');

String _join(List<String> parts) => _cut(
  [
    for (final s in parts)
      if (s.trim().isNotEmpty) s.trim(),
  ].join(', '),
  ImagePromptLimit.chars,
);

String _firstSentence(String text) {
  final t = text.trim();
  final end = RegExp(r'[.!?](\s|$)').firstMatch(t);
  return _cut(end == null ? t : t.substring(0, end.start + 1), 240);
}

String _cut(String text, int max) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= max ? t : '${t.substring(0, max).trimRight()}…';
}

/// How long a prompt "Draw it" fills in may be.
abstract final class ImagePromptLimit {
  static const chars = 1200;
}

/// Draws a picture for a world or character with the app's own drawing,
/// with the words filled in, as many tries as wanted; gives back the one
/// kept, or null. Tries not kept are deleted.
class VocesDrawDialog extends StatefulWidget {
  const VocesDrawDialog({
    super.key,
    required this.prompt,
    required this.wide,
    required this.folder,
  });

  final String prompt;
  final bool wide;
  final String folder;

  @override
  State<VocesDrawDialog> createState() => _VocesDrawDialogState();
}

class _VocesDrawDialogState extends State<VocesDrawDialog> {
  final _tries = <File>[];
  File? _shown;

  /// Drawings still on their way: kept as tries, or deleted when the
  /// dialog has closed.
  final _pending = <DrawJob>{};
  var _closed = false;

  void _queued(DrawJob job) {
    _pending.add(job);
    job.done.then((_) {}, onError: (_) {}).whenComplete(() {
      _pending.remove(job);
    });
  }

  void _drawn(File f) {
    if (_closed || !mounted) {
      unawaited(_delete(f));
      return;
    }
    setState(() {
      _tries.add(f);
      _shown = f;
    });
  }

  Future<void> _close(File? keep) async {
    _closed = true;
    for (final f in _tries) {
      if (f != keep) await _delete(f);
    }
    if (mounted) Navigator.pop(context, keep);
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await PictureInfo.deleteFor(f);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final engine = services.imageEngine;
    final palette = context.palette;
    final screen = MediaQuery.sizeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.settings, engine]),
      builder: (context, _) {
        final s = services.settings.value;
        final ready = s.imageEngine == ImageEngineChoice.off
            ? const <ImageModel>[]
            : engine.available(s);
        final title = Text(
          widget.wide ? 'Draw the world' : 'Draw a portrait',
          style: Theme.of(context).textTheme.titleLarge,
        );
        if (ready.isEmpty) {
          return AlertDialog(
            title: title,
            content: Text(
              s.imageEngine == ImageEngineChoice.off
                  ? 'Drawing is switched off. Switch it on in Settings → '
                        'Images and download a picture model, then come '
                        'back here.'
                  : 'There is no picture model yet. Download one in '
                        'Settings → Images, then come back here.',
            ),
            actions: [
              TextButton(
                onPressed: () => _close(null),
                child: const Text('Close'),
              ),
            ],
          );
        }
        final panel = DrawPanel(
          folder: widget.folder,
          prompt: widget.prompt,
          title: 'What to draw',
          shape: widget.wide ? 'landscape' : 'portrait',
          onJob: _queued,
          onDrawn: _drawn,
        );
        final preview = _Preview(
          wide: widget.wide,
          tries: _tries,
          shown: _shown,
          drawing: _pending.isNotEmpty,
          onShow: (f) => setState(() => _shown = f),
        );
        final wideLayout = screen.width >= 980;
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 1200,
              maxHeight: screen.height * 0.9,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  title,
                  const SizedBox(height: 14),
                  Flexible(
                    child: wideLayout
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: SingleChildScrollView(child: panel),
                              ),
                              const SizedBox(width: 18),
                              Expanded(flex: 2, child: preview),
                            ],
                          )
                        : SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                panel,
                                const SizedBox(height: 14),
                                SizedBox(
                                  height: widget.wide ? 300 : 420,
                                  child: preview,
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _tries.isEmpty
                              ? 'Tries show on the right; the ones you '
                                    'don\'t use are deleted.'
                              : '${_tries.length} '
                                    '${_tries.length == 1 ? 'try' : 'tries'}'
                                    '; the ones you don\'t use are deleted.',
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textMuted,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _close(null),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _shown == null ? null : () => _close(_shown),
                        child: const Text('Use this'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The try shown big, and a strip of every try to pick from.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.wide,
    required this.tries,
    required this.shown,
    required this.drawing,
    required this.onShow,
  });

  final bool wide;
  final List<File> tries;
  final File? shown;
  final bool drawing;
  final ValueChanged<File> onShow;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(minHeight: 240),
            decoration: BoxDecoration(
              color: palette.tile,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.glassBorder),
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: shown != null
                ? Image.file(shown!, fit: BoxFit.contain)
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (drawing)
                          const SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        else
                          Icon(
                            Icons.image_outlined,
                            size: 36,
                            color: palette.textMuted,
                          ),
                        const SizedBox(height: 10),
                        Text(
                          drawing
                              ? 'Drawing…'
                              : 'Your picture shows here. Press Draw.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: palette.textMuted),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        if (tries.length > 1 || drawing && tries.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in tries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onShow(f),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            width: 2,
                            color: f == shown ? accent : Colors.transparent,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            f,
                            width: wide ? 92 : 42,
                            height: 56,
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (drawing)
                  SizedBox(
                    width: wide ? 92 : 42,
                    child: const Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
