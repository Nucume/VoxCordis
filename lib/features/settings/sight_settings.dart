import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/runtime/model_catalog.dart';
import '../../theme/app_theme.dart';
import 'model_picker.dart' show InfoIcon;

/// Settings → Brain → Sight: whether the companion sees the pictures its
/// human shares, a vision file for an attached model, and Eyes, the small
/// vision model that describes pictures for a model that can't see.
class SightSettings extends StatefulWidget {
  const SightSettings({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<SightSettings> createState() => _SightSettingsState();
}

class _SightSettingsState extends State<SightSettings> {
  String? _error;

  AppSettings get _v => widget.value;

  Future<void> _attachMmproj() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Vision file (mmproj .gguf)', extensions: ['gguf']),
      ],
    );
    if (file == null) return;
    widget.onChanged(_v.copyWith(mmprojPath: file.path));
  }

  Future<void> _downloadEyes() async {
    setState(() => _error = null);
    try {
      await AppScope.of(
        context,
      ).runtime.download(ModelCatalog.eyes, ModelCatalog.dirFor(_v));
    } catch (e) {
      if (mounted) setState(() => _error = 'Eyes: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _removeEyes() async {
    final runtime = AppScope.of(context).runtime;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Eyes?'),
        content: const SizedBox(
          width: 400,
          child: Text(
            'Its files are deleted. Pictures already looked at keep their '
            'descriptions; new ones go unseen unless the brain can see.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await runtime.stopEyes();
    final dir = ModelCatalog.dirFor(_v);
    for (final path in ModelCatalog.eyes.allFiles) {
      final f = ModelCatalog.partFor(dir, path);
      if (await f.exists()) await f.delete();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final runtime = AppScope.of(context).runtime;
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);
    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        final builtIn = _v.llmMode == LlmMode.builtIn;
        final path = _v.modelPath;
        final catalog = path == null ? null : ModelCatalog.forPath(path);
        final attached = builtIn && path != null && catalog == null;
        final eyesReady = ModelCatalog.eyesInstalled(_v);
        final sees = builtIn && ModelCatalog.mmprojFor(_v) != null;
        final name = _v.companionName;
        final modelName = catalog?.name ?? 'Your model';
        final status = !builtIn
            ? 'Pictures you share go to the server-hosted model with your '
                  'message. ${eyesReady ? 'If it can\'t see, Eyes describes them on this computer instead.' : 'If it can\'t see, $name is only told a picture was shared, unless you get Eyes below.'}'
            : sees
            ? '$modelName sees the pictures you share itself.'
            : eyesReady
            ? '$modelName can\'t see, so Eyes looks at the pictures you share '
                  'and describes them for $name.'
            : '$modelName can\'t see pictures. Get Eyes below, or pick a '
                  'model that can see, such as Qwen3-VL.';
        final eyes = ModelCatalog.eyes;
        final downloading = runtime.downloads.containsKey(eyes.id);
        final progress = runtime.downloads[eyes.id];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sight',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  sees || eyesReady || !builtIn
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: context.palette.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(status, style: muted)),
              ],
            ),
            if (attached) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _v.mmprojPath == null
                        ? 'Vision file: none'
                        : 'Vision file: ${p.basename(_v.mmprojPath!)}'
                              '${File(_v.mmprojPath!).existsSync() ? '' : ' (not found)'}',
                  ),
                  const InfoIcon(
                    message:
                        'A model that can see comes with a second file, its '
                        'vision part, usually named mmproj-….gguf on the '
                        "model's page. Attach it here to let the model see "
                        'the pictures you share.',
                  ),
                  OutlinedButton.icon(
                    onPressed: _attachMmproj,
                    icon: const Icon(Icons.attach_file_rounded),
                    label: const Text('Attach vision file'),
                  ),
                  if (_v.mmprojPath != null)
                    TextButton(
                      onPressed: () =>
                          widget.onChanged(_v.copyWith(clearMmproj: true)),
                      child: const Text('Remove'),
                    ),
                ],
              ),
            ],
            if (!sees || eyesReady || downloading) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                decoration: BoxDecoration(
                  color: context.palette.tile,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Eyes',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'A small vision model (Qwen3-VL 4B, uncensored) '
                            'that looks at each picture once and describes '
                            'it for $name, so any model can talk about your '
                            'pictures. It runs on this computer, loads only '
                            'while it looks, and needs about '
                            '${eyes.minMemoryGb} GB of memory then.\n'
                            '${eyes.sizeGb.toStringAsFixed(1)} GB download',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: context.palette.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    if (downloading)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 120,
                            child: LinearProgressIndicator(
                              value: progress,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            progress == null
                                ? '…'
                                : '${(progress * 100).round()}%',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.palette.textMuted,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Pause download',
                            onPressed: () => runtime.cancelDownload(eyes.id),
                            icon: const Icon(Icons.pause_rounded),
                          ),
                        ],
                      )
                    else if (eyesReady)
                      TextButton(
                        onPressed: _removeEyes,
                        child: const Text('Remove'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _downloadEyes,
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Download'),
                      ),
                  ],
                ),
              ),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        );
      },
    );
  }
}
