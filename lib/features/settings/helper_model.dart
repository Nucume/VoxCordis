import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../services/runtime/model_catalog.dart';
import '../../theme/app_theme.dart';
import '../../widgets/download_bar.dart';

/// The top of a section about one of the small helper models (Eyes,
/// Recall): its title and one line on how things stand right now.
class HelperStatus extends StatelessWidget {
  const HelperStatus({
    super.key,
    required this.title,
    required this.icon,
    required this.status,
  });

  final String title;
  final IconData icon;
  final String status;

  @override
  Widget build(BuildContext context) {
    final muted = context.palette.textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(status, style: TextStyle(color: muted, height: 1.4)),
            ),
          ],
        ),
      ],
    );
  }
}

/// The tile for a small helper model: what it is, and its download with
/// progress and pause, or Remove once it is there. Place it under a
/// listener of the runtime, which says how the download is going.
class HelperModelTile extends StatelessWidget {
  const HelperModelTile({
    super.key,
    required this.name,
    required this.about,
    required this.model,
    required this.ready,
    required this.onDownload,
    required this.onRemove,
  });

  final String name;
  final String about;
  final CatalogModel model;
  final bool ready;
  final VoidCallback onDownload;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final runtime = AppScope.of(context).runtime;
    return Container(
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
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  '$about\n${model.sizeGb.toStringAsFixed(1)} GB download',
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
          if (runtime.downloads.containsKey(model.id))
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 170,
                  child: DownloadBar(progress: runtime.downloads[model.id]),
                ),
                IconButton(
                  tooltip: 'Pause download',
                  onPressed: () => runtime.cancelDownload(model.id),
                  icon: const Icon(Icons.pause_rounded),
                ),
              ],
            )
          else if (ready)
            TextButton(onPressed: onRemove, child: const Text('Remove'))
          else
            OutlinedButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download'),
            ),
        ],
      ),
    );
  }
}

/// Asks before a helper model's files are deleted. [after] says what
/// that means for the human.
Future<bool> confirmRemoveHelper(
  BuildContext context,
  String name,
  String after,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: SizedBox(width: 400, child: Text(after)),
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
    ) ??
    false;
