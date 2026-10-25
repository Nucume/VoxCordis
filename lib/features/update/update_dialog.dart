import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../services/updater.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_text.dart';

/// Shows what's new and updates with one button. The app restarts itself.
Future<void> showUpdateDialog(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _UpdateDialog());

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog();

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final updater = services.updates;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final info = updater.available;
        if (info == null) {
          return AlertDialog(
            title: const Text('VoxCordis is up to date'),
            content: Text('You have version $appVersion.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        }
        final working =
            updater.status == UpdateStatus.downloading ||
            updater.status == UpdateStatus.installing;
        final accent = Theme.of(context).colorScheme.primary;
        return AlertDialog(
          title: Text('VoxCordis ${info.version} is available'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You have $appVersion.',
                  style: TextStyle(color: context.palette.textMuted),
                ),
                if (info.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 14),
                        child: SelectableText.rich(
                          formatChat(
                            info.notes,
                            actionColor: Color.lerp(
                              context.palette.text,
                              accent,
                              0.7,
                            )!,
                            codeFill: context.palette.codeFill,
                          ),
                          style: const TextStyle(height: 1.4),
                        ),
                      ),
                    ),
                  ),
                ],
                if (!info.canInstall) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'This copy of VoxCordis can\'t update itself. Download '
                    'the new version from the release page.',
                  ),
                ],
                if (working) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: updater.status == UpdateStatus.installing
                        ? null
                        : updater.progress,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    updater.status == UpdateStatus.installing
                        ? 'Restarting…'
                        : _downloaded(updater.progress, info.assetSize),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.textMuted,
                    ),
                  ),
                ],
                if (updater.error case final e?) ...[
                  const SizedBox(height: 12),
                  Text(e, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(context),
              child: const Text('Later'),
            ),
            if (info.canInstall)
              FilledButton.icon(
                onPressed: working
                    ? null
                    : () => updater.install(
                        info,
                        beforeExit: services.runtime.stop,
                      ),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Update and restart'),
              )
            else
              FilledButton.icon(
                onPressed: () => launchUrl(Uri.parse(info.pageUrl)),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open release page'),
              ),
          ],
        );
      },
    );
  }

  static String _downloaded(double? progress, int? size) {
    if (progress == null || size == null) return 'Downloading…';
    final mb = size / (1024 * 1024);
    return 'Downloading ${(progress * mb).round()} of ${mb.round()} MB';
  }
}

/// Top bar pill that appears only when an update is waiting.
class UpdatePill extends StatelessWidget {
  const UpdatePill({super.key});

  @override
  Widget build(BuildContext context) {
    final updater = AppScope.of(context).updates;
    final accent = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final info = updater.available;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: info == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Tooltip(
                    message: 'VoxCordis ${info.version} is available',
                    child: ActionChip(
                      avatar: Icon(
                        Icons.arrow_circle_up_rounded,
                        size: 18,
                        color: accent,
                      ),
                      label: const Text('Update'),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      backgroundColor: accent.withValues(alpha: 0.15),
                      shape: const StadiumBorder(),
                      onPressed: () => showUpdateDialog(context),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
