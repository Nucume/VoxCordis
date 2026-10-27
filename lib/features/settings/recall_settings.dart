import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/runtime/model_catalog.dart';
import '../../theme/app_theme.dart';

/// Settings → Brain → Recall: the small embedding model that finds
/// memories and older chat by meaning.
class RecallSettings extends StatefulWidget {
  const RecallSettings({super.key, required this.value});

  final AppSettings value;

  @override
  State<RecallSettings> createState() => _RecallSettingsState();
}

class _RecallSettingsState extends State<RecallSettings> {
  String? _error;

  AppSettings get _v => widget.value;

  Future<void> _download() async {
    setState(() => _error = null);
    final services = AppScope.of(context);
    try {
      await services.runtime.download(
        ModelCatalog.recall,
        ModelCatalog.dirFor(_v),
      );
      // Everything said and remembered so far becomes findable.
      services.recall.update().ignore();
    } catch (e) {
      if (mounted) setState(() => _error = 'Recall: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _remove() async {
    final runtime = AppScope.of(context).runtime;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Recall?'),
        content: const SizedBox(
          width: 400,
          child: Text(
            'Its file is deleted and memories are matched by words again. '
            'Nothing is forgotten.',
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
    await runtime.stopRecall();
    final f = ModelCatalog.fileFor(
      ModelCatalog.dirFor(_v),
      ModelCatalog.recall,
    );
    if (await f.exists()) await f.delete();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final runtime = AppScope.of(context).runtime;
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);
    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        final name = _v.companionName;
        final ready = ModelCatalog.recallInstalled(_v);
        final recall = ModelCatalog.recall;
        final downloading = runtime.downloads.containsKey(recall.id);
        final progress = runtime.downloads[recall.id];
        final status = ready
            ? 'Before each reply, $name is given the memories and the older '
                  'moments of your chat that fit what you said, found by '
                  'meaning.'
            : 'Memories are found by matching words in your message. Get '
                  'Recall below so $name finds memories and older chat by '
                  'meaning instead.';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Memory',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  ready
                      ? Icons.psychology_outlined
                      : Icons.manage_search_rounded,
                  size: 18,
                  color: context.palette.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(status, style: muted)),
              ],
            ),
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
                          'Recall',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'A small embedding model (EmbeddingGemma 300M) that '
                          'turns memories and chat into numbers VoxCordis can '
                          'compare by meaning, in many languages. It runs on '
                          'this computer, on the processor, works with any '
                          'brain, server-hosted ones too, and needs about half '
                          'a gigabyte of memory while loaded.\n'
                          '${recall.sizeGb.toStringAsFixed(1)} GB download',
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
                          onPressed: () => runtime.cancelDownload(recall.id),
                          icon: const Icon(Icons.pause_rounded),
                        ),
                      ],
                    )
                  else if (ready)
                    TextButton(onPressed: _remove, child: const Text('Remove'))
                  else
                    OutlinedButton.icon(
                      onPressed: _download,
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Download'),
                    ),
                ],
              ),
            ),
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
