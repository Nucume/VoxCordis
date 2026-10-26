import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_scope.dart';
import '../data/desk/pictures.dart';
import '../data/settings.dart';
import '../features/chat/chat_controller.dart';
import '../services/folder_service.dart';
import '../theme/app_theme.dart';
import 'companion_switcher.dart';
import 'portrait.dart';
import 'runtime_status.dart';
import 'wordmark.dart';

/// Left-hand card: portrait, name, traits, the days with chats, and
/// the button that opens the companion folder in the OS file manager.
/// Trait tags shown on the card; the rest sit behind a "+n" tag.
const _shownTraits = 8;

class CompanionCard extends StatelessWidget {
  const CompanionCard({super.key, required this.chat, required this.onOpenDay});

  final ChatController chat;
  final ValueChanged<DateTime> onOpenDay;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final s = services.settings.value;
        return GlassPanel(
          blur: GlassPanel.still,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Large portrait across the top of the card: avatar.png in
              // the companion's folder, which it picks itself. Without one
              // it wears the VoxCordis heart. A tap on it or the name opens
              // the companion menu.
              CompanionSwitcher(
                chat: chat,
                builder: (context, open) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(
                    children: [
                      Stack(
                        children: [
                          Portrait(
                            path: s.companionFolder == null
                                ? s.portraitPath
                                : Pictures.avatarIn(s.companionFolder!)?.path ??
                                      s.portraitPath,
                          ),
                          if (s.statusLight == StatusLight.portrait)
                            // Discord-style: a large light with a ring in
                            // the card's colour, on the bottom-right corner.
                            const Positioned(
                              right: 0,
                              bottom: 0,
                              child: RuntimeStatus(dot: true, size: 26),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              s.companionName,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (s.statusLight == StatusLight.name) ...[
                            const SizedBox(width: 8),
                            const RuntimeStatus(dot: true),
                          ],
                          const SizedBox(width: 6),
                          AnimatedRotation(
                            turns: open ? 0.5 : 0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutBack,
                            child: Icon(
                              Icons.expand_more_rounded,
                              size: 22,
                              color: context.palette.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in s.traits.take(_shownTraits))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(t, style: const TextStyle(fontSize: 12)),
                    ),
                  if (s.traits.length > _shownTraits)
                    Tooltip(
                      message: s.traits.skip(_shownTraits).join(', '),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: accent.withValues(alpha: 0.3),
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '+${s.traits.length - _shownTraits}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'DAYS',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.4,
                  color: context.palette.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: _DayList(chat: chat, onOpenDay: onOpenDay),
              ),
              const SizedBox(height: 12),
              const Center(child: Wordmark()),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: s.companionFolder == null
                    ? null
                    : () => CompanionFolder(
                        s.companionFolder!,
                      ).openInFileManager(),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Open folder'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DayList extends StatelessWidget {
  const _DayList({required this.chat, required this.onOpenDay});

  final ChatController chat;
  final ValueChanged<DateTime> onOpenDay;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        final days = chat.days;
        if (days.isEmpty) {
          return Text(
            'No chats yet',
            style: TextStyle(color: context.palette.textMuted),
          );
        }
        final now = DateTime.now();
        final fmt = DateFormat('EEE d MMM');
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            for (final d in days)
              ListTile(
                dense: true,
                selected: chat.viewingDay == null
                    ? DateUtils.isSameDay(d, now)
                    : DateUtils.isSameDay(d, chat.viewingDay),
                selectedTileColor: accent.withValues(alpha: 0.18),
                selectedColor: context.palette.text,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                title: Text(
                  DateUtils.isSameDay(d, now) ? 'Today' : fmt.format(d),
                ),
                onTap: () => onOpenDay(d),
              ),
          ],
        );
      },
    );
  }
}
