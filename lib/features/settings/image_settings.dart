import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/images/image_catalog.dart';
import '../../services/invoke_client.dart';
import '../../services/images/sd_runtime.dart';
import '../../theme/app_theme.dart';

/// Settings → Images: whether the companion may draw, the picture models
/// and LoRAs, and the graphics card. The switches are saved with the page's
/// Save button; downloads, added files and deletes happen at once.
class ImageSettings extends StatefulWidget {
  const ImageSettings({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<ImageSettings> createState() => _ImageSettingsState();
}

class _ImageSettingsState extends State<ImageSettings> {
  AppSettings get _v => widget.value;
  late final _invokeUrl = TextEditingController(text: _v.invokeUrl);

  /// Invoke's version once looked for, null while looking or unreachable.
  Future<String?>? _invokeVersion;

  @override
  void dispose() {
    _invokeUrl.dispose();
    super.dispose();
  }

  /// Asks Invoke at the typed address for its version and what it has.
  void _checkInvoke() {
    final engine = AppScope.of(context).imageEngine;
    final s = _v.copyWith(invokeUrl: _invokeUrl.text.trim());
    setState(() {
      _invokeVersion = engine.invokeFor(s).ping().then((v) async {
        if (v != null) await engine.refreshInvoke(s);
        return v;
      });
    });
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _download(ImageModel m) async {
    final engine = AppScope.of(context).imageEngine;
    try {
      await engine.download(m);
      if (!mounted) return;
      if (_v.imageModel == null) {
        widget.onChanged(_v.copyWith(imageModel: m.id));
      }
      setState(() {});
    } catch (e) {
      if (mounted) _say('${m.name} wasn\'t downloaded: $e');
    }
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _delete(ImageModel m) async {
    final ok = await _confirm(
      'Delete ${m.name}?',
      m.own
          ? 'Its file is deleted from the picture models folder.'
          : 'You can download it again later.',
    );
    if (!ok || !mounted) return;
    await AppScope.of(context).imageEngine.delete(m);
    if (mounted) setState(() {});
  }

  Future<void> _deleteLora(String name) async {
    if (!await _confirm('Delete $name?', 'Its file and note are deleted.')) {
      return;
    }
    final dir = ImageCatalog.lorasFor(_v);
    for (final ext in const ['.safetensors', '.gguf', '.txt']) {
      final f = File(p.join(dir.path, '$name$ext'));
      if (await f.exists()) await f.delete();
    }
    if (mounted) setState(() {});
  }

  /// Copies a file the human picks into [dir].
  Future<void> _addFile(
    Directory dir,
    List<String> extensions,
    String label,
  ) async {
    final file = await openFile(
      acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
    );
    if (file == null) return;
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, p.basename(file.path)));
    if (await target.exists()) {
      _say('${p.basename(file.path)} is already there.');
      return;
    }
    _say('Copying ${p.basename(file.path)}…');
    try {
      await File(file.path).copy('${target.path}.copying');
      await File('${target.path}.copying').rename(target.path);
    } catch (e) {
      _say('Couldn\'t copy it: $e');
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _open(Directory dir) async {
    await dir.create(recursive: true);
    await launchUrl(Uri.directory(dir.path));
  }

  /// Invoke's address, whether it answers, and the models and LoRAs it
  /// has. Those are installed and managed in Invoke itself.
  Widget _invoke(TextStyle muted, TextStyle sectionStyle) {
    if (_invokeVersion == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _invokeVersion == null) _checkInvoke();
      });
    }
    final engine = AppScope.of(context).imageEngine;
    final s = _v;
    final ready = engine.available(s);
    final loras = engine.invokeUrl == s.invokeUrl
        ? engine.invokeCatalog?.loras ?? const <InvokeModel>[]
        : const <InvokeModel>[];
    final usual = ImageCatalog.defaultFor(s, ready)?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _invokeUrl,
                onChanged: (v) =>
                    widget.onChanged(_v.copyWith(invokeUrl: v.trim())),
                onSubmitted: (_) => _checkInvoke(),
                decoration: const InputDecoration(
                  labelText: 'Invoke address',
                  hintText: 'http://localhost:9090',
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _checkInvoke, child: const Text('Check')),
          ],
        ),
        const SizedBox(height: 10),
        FutureBuilder<String?>(
          future: _invokeVersion,
          builder: (context, snap) {
            final looking = snap.connectionState != ConnectionState.done;
            final version = snap.data;
            final ok = version != null;
            return Row(
              children: [
                Icon(
                  looking
                      ? Icons.more_horiz_rounded
                      : ok
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: looking
                      ? context.palette.textMuted
                      : ok
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    looking
                        ? 'Looking for Invoke…'
                        : ok
                        ? 'Invoke $version is running: ${ready.length} '
                              'model${ready.length == 1 ? '' : 's'} and '
                              '${loras.length} LoRA${loras.length == 1 ? '' : 's'} '
                              '${s.companionName} can use.'
                        : 'Invoke isn\'t answering at this address. Start it, '
                              'or check the address.',
                    style: TextStyle(color: context.palette.text),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Models and LoRAs are installed in Invoke, and ${s.companionName} '
          'sees them here. Stable Diffusion 1.5, 2 and SDXL models work; '
          'Invoke\'s FLUX and other kinds are left out for now.',
          style: muted,
        ),
        if (ready.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Models in Invoke', style: sectionStyle),
          const SizedBox(height: 8),
          for (final m in ready)
            _ModelTile(
              model: m,
              installed: true,
              usual: usual == m.id,
              onUsual: () => widget.onChanged(s.copyWith(imageModel: m.id)),
            ),
        ],
        if (loras.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('LoRAs in Invoke', style: sectionStyle),
          const SizedBox(height: 4),
          for (final l in loras)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.layers_outlined, size: 20),
              title: Text(l.name),
              subtitle: Text(
                l.note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).imageEngine;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final s = _v;
        final palette = context.palette;
        final dir = ImageCatalog.dirFor(s);
        final ready = ImageCatalog.available(dir);
        final own = ImageCatalog.own(dir);
        final loras = ImageCatalog.loras(ImageCatalog.lorasFor(s));
        final usual = ImageCatalog.defaultFor(s, ready)?.id;
        final sectionStyle = TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: palette.text,
        );
        final muted = TextStyle(fontSize: 12.5, color: palette.textMuted);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.imageEngine != ImageEngineChoice.off,
              onChanged: SdInstaller.supported
                  ? (v) => widget.onChanged(
                      s.copyWith(
                        imageEngine: v
                            ? ImageEngineChoice.builtIn
                            : ImageEngineChoice.off,
                      ),
                    )
                  : null,
              title: Text('Let ${s.companionName} draw'),
              subtitle: Text(
                s.imageEngine == ImageEngineChoice.invoke
                    ? '${s.companionName} picks a model and LoRAs from your '
                          'Invoke, and the picture comes back into the chat.'
                    : SdInstaller.supported
                    ? 'Drawn on this computer with stable-diffusion.cpp: '
                          'nothing leaves it. ${s.companionName} picks the '
                          'model and LoRAs that suit each picture. The '
                          'drawing engine (about 35 MB) downloads with the '
                          'first picture.'
                    : 'Drawing isn\'t available for this computer yet.',
                style: muted,
              ),
            ),
            if (s.imageEngine != ImageEngineChoice.off) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('Draw with', style: TextStyle(color: palette.text)),
                  const SizedBox(width: 14),
                  SegmentedButton<ImageEngineChoice>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ImageEngineChoice.builtIn,
                        icon: Icon(Icons.memory_rounded, size: 18),
                        label: Text('This app'),
                      ),
                      ButtonSegment(
                        value: ImageEngineChoice.invoke,
                        icon: Icon(Icons.lan_outlined, size: 18),
                        label: Text('Invoke'),
                      ),
                    ],
                    selected: {s.imageEngine},
                    onSelectionChanged: (v) {
                      widget.onChanged(s.copyWith(imageEngine: v.single));
                      if (v.single == ImageEngineChoice.invoke) _checkInvoke();
                    },
                  ),
                ],
              ),
            ],
            if (s.imageEngine == ImageEngineChoice.invoke) ...[
              const SizedBox(height: 14),
              _invoke(muted, sectionStyle),
            ] else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.freeGpuForDrawing,
                onChanged: (v) =>
                    widget.onChanged(s.copyWith(freeGpuForDrawing: v)),
                title: const Text('Free the graphics card while drawing'),
                subtitle: Text(
                  'The chat model steps aside while a picture is drawn, '
                  'which is much faster on most cards. It loads again for '
                  'the next message.',
                  style: muted,
                ),
              ),
              const SizedBox(height: 18),
              Text('Picture models', style: sectionStyle),
              const SizedBox(height: 8),
              for (final m in ImageCatalog.models)
                _ModelTile(
                  model: m,
                  installed: ImageCatalog.installed(dir, m),
                  usual: usual == m.id,
                  progress: engine.downloads[m.id],
                  downloading: engine.downloads.containsKey(m.id),
                  onDownload: () => _download(m),
                  onCancel: () => engine.cancelDownload(m.id),
                  onDelete: () => _delete(m),
                  onUsual: () => widget.onChanged(s.copyWith(imageModel: m.id)),
                ),
              for (final m in own)
                _ModelTile(
                  model: m,
                  installed: true,
                  usual: usual == m.id,
                  onDelete: () => _delete(m),
                  onUsual: () => widget.onChanged(s.copyWith(imageModel: m.id)),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => _addFile(dir, const [
                      'safetensors',
                      'gguf',
                      'ckpt',
                    ], 'Picture models'),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add your own model…'),
                  ),
                  TextButton.icon(
                    onPressed: () => _open(dir),
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Open the folder'),
                  ),
                ],
              ),
              Text(
                'Your own models: single-file Stable Diffusion 1.5 or SDXL '
                'checkpoints (Pony and Illustrious too), as Civitai offers them.',
                style: muted,
              ),
              const SizedBox(height: 22),
              Text('LoRAs', style: sectionStyle),
              const SizedBox(height: 4),
              Text(
                'Small add-ons for a style, a character or a detail. A .txt '
                'file with the same name beside one tells ${s.companionName} '
                'its trigger words and what it is for. A LoRA works only with '
                'models of its own kind (SDXL, SD 1.5 or Anima).',
                style: muted,
              ),
              const SizedBox(height: 8),
              for (final l in loras)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.layers_outlined, size: 20),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline_rounded, size: 19),
                    onPressed: () => _deleteLora(l.name),
                  ),
                  title: Text(l.name),
                  subtitle: l.note.isEmpty
                      ? null
                      : Text(
                          l.note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => _addFile(ImageCatalog.lorasFor(s), const [
                      'safetensors',
                      'gguf',
                    ], 'LoRAs'),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add a LoRA…'),
                  ),
                  TextButton.icon(
                    onPressed: () => _open(ImageCatalog.lorasFor(s)),
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Open the folder'),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.installed,
    required this.usual,
    this.progress,
    this.downloading = false,
    this.onDownload,
    this.onCancel,
    this.onDelete,
    required this.onUsual,
  });

  final ImageModel model;
  final bool installed;
  final bool usual;
  final double? progress;
  final bool downloading;
  final VoidCallback? onDownload;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;
  final VoidCallback onUsual;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final m = model;
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: usual
              ? Theme.of(context).colorScheme.primary
              : palette.glassBorder,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  usual ? '${m.name} · your usual one' : m.name,
                  style: TextStyle(color: palette.text),
                ),
                const SizedBox(height: 2),
                Text(
                  m.blurb,
                  style: TextStyle(fontSize: 12.5, color: palette.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    m.style,
                    if (m.files.isNotEmpty || m.own && m.sizeGb > 0)
                      '${m.sizeGb.toStringAsFixed(1)} GB',
                    if (!m.own) 'about ${m.minMemoryGb} GB graphics memory',
                  ].join(' · '),
                  style: muted,
                ),
                if (m.license != null) Text(m.license!, style: muted),
                if (downloading) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: progress),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (downloading)
            TextButton(onPressed: onCancel, child: const Text('Cancel'))
          else if (!installed)
            FilledButton.tonal(
              onPressed: onDownload,
              child: const Text('Download'),
            )
          else ...[
            if (!usual)
              TextButton(onPressed: onUsual, child: const Text('Use usually')),
            if (onDelete != null)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
                onPressed: onDelete,
              ),
          ],
        ],
      ),
    );
  }
}
