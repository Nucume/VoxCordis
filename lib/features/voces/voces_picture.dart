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
import '../../services/images/sd_runtime.dart';
import '../../theme/app_theme.dart';
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

/// What "Draw it" starts from for a character: a portrait, their looks
/// first, then traits and line.
String characterPrompt({
  required String? pronouns,
  required List<String> tags,
  required String line,
  required List<SheetSection> sections,
}) {
  final who = (pronouns ?? '').toLowerCase();
  final looks = [
    for (final s in sections)
      if (RegExp(
        r'look|appear|body|physic|outfit',
        caseSensitive: false,
      ).hasMatch(s.heading))
        s.text,
  ].join(' ');
  return _join([
    'portrait',
    'upper body',
    'solo',
    if (who.startsWith('she')) '1girl' else if (who.startsWith('he')) '1boy',
    'looking at viewer',
    _cut(looks, 600),
    ...tags,
    line,
  ]);
}

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
  late final _prompt = TextEditingController(text: widget.prompt);
  final _tries = <File>[];
  File? _shown;
  DrawJob? _job;
  String? _error;
  String? _model;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _draw(AppSettings s, List<ImageModel> ready) async {
    final engine = AppScope.of(context).imageEngine;
    final model = ready.firstWhere(
      (m) => m.id == _model,
      orElse: () => ImageCatalog.defaultFor(s, ready) ?? ready.first,
    );
    final job = engine.draw(
      DrawJob(
        DrawRequest(
          model: model,
          prompt: _prompt.text.trim(),
          shape: widget.wide ? 'landscape' : 'portrait',
        ),
        folder: widget.folder,
        forChat: false,
      ),
    );
    setState(() {
      _job = job;
      _error = null;
    });
    try {
      final f = await job.done;
      if (!mounted) {
        await _delete(f);
        return;
      }
      setState(() {
        _tries.add(f);
        _shown = f;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _job = null);
    }
  }

  Future<void> _close(File? keep) async {
    for (final f in _tries) {
      if (f != keep) await _delete(f);
    }
    // One still drawing goes once it's done.
    unawaited(_job?.done.then(_delete, onError: (_) {}));
    if (mounted) Navigator.pop(context, keep);
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final engine = services.imageEngine;
    final palette = context.palette;
    return ListenableBuilder(
      listenable: Listenable.merge([services.settings, engine]),
      builder: (context, _) {
        final s = services.settings.value;
        final ready = s.imageEngine == ImageEngineChoice.off
            ? const <ImageModel>[]
            : engine.available(s);
        final drawing = _job != null;
        final mine = drawing && engine.current == _job;
        final muted = TextStyle(fontSize: 12, color: palette.textMuted);
        return AlertDialog(
          title: Text(widget.wide ? 'Draw the world' : 'Draw a portrait'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              // Room for the first field's floating label.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ready.isEmpty)
                    Text(
                      s.imageEngine == ImageEngineChoice.off
                          ? 'Drawing is switched off. Switch it on in '
                                'Settings → Images and download a picture '
                                'model, then come back here.'
                          : 'There is no picture model yet. Download one in '
                                'Settings → Images, then come back here.',
                    )
                  else ...[
                    TextField(
                      controller: _prompt,
                      minLines: 3,
                      maxLines: 8,
                      enabled: !drawing,
                      decoration: const InputDecoration(
                        labelText: 'What to draw',
                        alignLabelWithHint: true,
                        helperText:
                            'Filled in from what you wrote; change anything.',
                      ),
                    ),
                    if (ready.length > 1) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue:
                            _model ?? ImageCatalog.defaultFor(s, ready)?.id,
                        decoration: const InputDecoration(labelText: 'Model'),
                        items: [
                          for (final m in ready)
                            DropdownMenuItem(value: m.id, child: Text(m.name)),
                        ],
                        onChanged: drawing
                            ? null
                            : (id) => setState(() => _model = id),
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (drawing)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(
                            value: mine ? engine.progress : null,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            mine
                                ? (engine.status ?? 'Drawing')
                                : 'Waiting for another picture to finish',
                            style: muted,
                          ),
                        ],
                      ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (_shown != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: AspectRatio(
                          aspectRatio: widget.wide ? 16 / 9 : 3 / 4,
                          child: Image.file(_shown!, fit: BoxFit.cover),
                        ),
                      ),
                    ],
                    if (_tries.length > 1) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 56,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final f in _tries)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => setState(() => _shown = f),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        width: 2,
                                        color: f == _shown
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Colors.transparent,
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.file(
                                        f,
                                        width: widget.wide ? 80 : 40,
                                        height: 52,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _close(null),
              child: const Text('Cancel'),
            ),
            if (ready.isNotEmpty)
              OutlinedButton(
                onPressed: drawing || _prompt.text.trim().isEmpty
                    ? null
                    : () => _draw(s, ready),
                child: Text(_tries.isEmpty ? 'Draw' : 'Draw again'),
              ),
            if (_shown != null)
              FilledButton(
                onPressed: drawing ? null : () => _close(_shown),
                child: const Text('Use this'),
              ),
          ],
        );
      },
    );
  }
}
