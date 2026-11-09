import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/runtime/model_catalog.dart';
import 'helper_model.dart';

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
    final ok = await confirmRemoveHelper(
      context,
      'Recall',
      'Its file is deleted and memories are matched by words again. '
          'Nothing is forgotten.',
    );
    if (!ok) return;
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
    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        final name = _v.companionName;
        final ready = ModelCatalog.recallInstalled(_v);
        final recall = ModelCatalog.recall;
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
            HelperStatus(
              title: 'Memory',
              icon: ready
                  ? Icons.psychology_outlined
                  : Icons.manage_search_rounded,
              status: status,
            ),
            const SizedBox(height: 12),
            HelperModelTile(
              name: 'Recall',
              about:
                  'A small embedding model (EmbeddingGemma 300M) that '
                  'turns memories and chat into numbers VoxCordis can '
                  'compare by meaning, in many languages. It runs on '
                  'this computer, on the processor, works with any '
                  'brain, server-hosted ones too, and needs about half '
                  'a gigabyte of memory while loaded.',
              model: recall,
              ready: ready,
              onDownload: _download,
              onRemove: _remove,
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
