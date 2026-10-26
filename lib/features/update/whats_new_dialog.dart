import 'package:flutter/material.dart';

import '../../services/changelog.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_text.dart';
import '../settings/settings_screen.dart';

/// Something a version's notes can offer to do, written in CHANGELOG.md as
/// a line of its own: `{{action:<id>}}`. Ids this build doesn't know are
/// left out, so an old line can never show a dead button.
class WhatsNewAction {
  const WhatsNewAction({
    required this.label,
    required this.icon,
    required this.run,
  });

  final String label;
  final IconData icon;

  /// Runs after the dialog has closed; [host] reaches the main window.
  final void Function(BuildContext context, WhatsNewHost host) run;
}

/// What an action may do to the window behind the dialog.
abstract interface class WhatsNewHost {
  /// Opens Settings on page [tab] (see [SettingsScreen.privacyTab]).
  void openSettings({int tab = 0});
}

/// Every action notes can offer, by id.
final whatsNewActions = <String, WhatsNewAction>{
  'open-settings': WhatsNewAction(
    label: 'Open Settings',
    icon: Icons.tune_rounded,
    run: (_, host) => host.openSettings(),
  ),
  'open-privacy': WhatsNewAction(
    label: 'Show my key',
    icon: Icons.key_rounded,
    run: (_, host) => host.openSettings(tab: SettingsScreen.privacyTab),
  ),
  'open-sight': WhatsNewAction(
    label: 'Set up sight',
    icon: Icons.visibility_outlined,
    run: (_, host) => host.openSettings(tab: SettingsScreen.brainTab),
  ),
  'open-internet': WhatsNewAction(
    label: 'Let it go online',
    icon: Icons.public_rounded,
    run: (_, host) => host.openSettings(tab: SettingsScreen.internetTab),
  ),
};

/// Shows [entries] (newest first) in one window: the newest version open
/// at the top, any versions skipped on the way folded underneath it.
Future<void> showWhatsNew(
  BuildContext context,
  List<ChangelogEntry> entries, {
  required WhatsNewHost host,
  String? updatedFrom,
}) {
  if (entries.isEmpty) return Future.value();
  return showDialog(
    context: context,
    builder: (_) =>
        _WhatsNewDialog(entries: entries, host: host, updatedFrom: updatedFrom),
  );
}

class _WhatsNewDialog extends StatelessWidget {
  const _WhatsNewDialog({
    required this.entries,
    required this.host,
    this.updatedFrom,
  });

  final List<ChangelogEntry> entries;
  final WhatsNewHost host;
  final String? updatedFrom;

  @override
  Widget build(BuildContext context) {
    final newest = entries.first;
    final skipped = entries.length - 1;
    return AlertDialog(
      title: Text('What\'s new in VoxCordis ${newest.version}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (updatedFrom != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  skipped == 0
                      ? 'You updated from $updatedFrom.'
                      : 'You updated from $updatedFrom, so this also covers '
                            '$skipped earlier ${skipped == 1 ? 'version' : 'versions'}.',
                  style: TextStyle(color: context.palette.textMuted),
                ),
              ),
            Flexible(
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Version(entry: newest, host: host, open: true),
                      for (final e in entries.skip(1))
                        _Version(entry: e, host: host, open: false),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

/// One version: its number, its notes and the buttons its notes offer.
class _Version extends StatelessWidget {
  const _Version({required this.entry, required this.host, required this.open});

  final ChangelogEntry entry;
  final WhatsNewHost host;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final actions = [
      for (final id in entry.actions)
        if (whatsNewActions[id] case final a?) a,
    ];
    final body = Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText.rich(
            formatChat(
              entry.notes,
              actionColor: Color.lerp(context.palette.text, accent, 0.7)!,
              codeFill: context.palette.codeFill,
            ),
            style: const TextStyle(height: 1.4),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final a in actions)
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      a.run(context, host);
                    },
                    icon: Icon(a.icon, size: 18),
                    label: Text(a.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    final title = Text(
      'Version ${entry.version}',
      style: TextStyle(fontWeight: FontWeight.w600, color: accent),
    );
    return Theme(
      // No divider lines above and below an opened version.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: open,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: title,
        children: [body],
      ),
    );
  }
}
