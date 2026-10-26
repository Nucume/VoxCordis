import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_screen.dart';
import '../features/images/images_screen.dart';
import '../features/memory/memory_screen.dart';
import '../features/schedule/schedule_screen.dart';
import '../features/settings/keep_key_dialog.dart';
import '../features/settings/settings_screen.dart';
import '../features/skills/skills_screen.dart';
import '../features/system/system_approval.dart';
import '../features/system/web_approval.dart';
import '../features/update/update_dialog.dart';
import '../features/update/whats_new_dialog.dart';
import '../data/settings.dart';
import '../services/schedule/scheduler.dart';
import '../services/system/system_tools.dart';
import '../theme/app_theme.dart';
import 'companion_card.dart';
import 'runtime_status.dart';

enum AppTab {
  chat('Chat', Icons.chat_bubble_outline_rounded),
  memory('Memory', Icons.auto_awesome_outlined),
  plans('Plans', Icons.alarm_rounded),
  skills('Skills', Icons.school_outlined),
  images('Images', Icons.image_outlined),
  settings('Settings', Icons.tune_rounded);

  const AppTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The frame every screen shares: the companion card on the left, tabs on top,
/// and the current screen cross-fading underneath.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> implements WhatsNewHost {
  AppTab _tab = AppTab.chat;
  ChatController? _chat;
  Scheduler? _scheduler;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showWhatsNew());
  }

  /// The first start after an update: what changed, once. Then, until the
  /// human has kept a copy of the encryption key, the card asking for that.
  Future<void> _showWhatsNew() async {
    if (!mounted) return;
    final services = AppScope.of(context);
    final news = services.whatsNew;
    services.whatsNew = null;
    if (news != null && news.notes.isNotEmpty) {
      await showWhatsNew(
        context,
        news.notes,
        host: this,
        updatedFrom: news.from,
      );
    }
    if (mounted && !services.dbKey.saved) await showKeepKey(context);
  }

  @override
  void openSettings({int tab = 0}) => setState(() {
    _tab = AppTab.settings;
    _settingsTab = tab;
  });

  /// The Settings page to open on.
  int _settingsTab = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = AppScope.of(context);
    _chat ??= ChatController(services)..load();
    services.systemTools.ask = (request) async {
      await services.background?.showWindow();
      if (!mounted) return SystemApproval.deny;
      return askSystemApproval(
        context,
        request,
        companionName: services.settings.value.companionName,
      );
    };
    services.webTools.ask = (request) async {
      await services.background?.showWindow();
      if (!mounted) return false;
      return askWebApproval(
        context,
        request,
        companionName: services.settings.value.companionName,
      );
    };
    _scheduler ??= Scheduler(
      repo: () => services.schedules,
      run: (item, {required late}) => _chat!.runScheduled(item, late: late),
      runsPerDay: () => services.settings.value.automationRunsPerDay,
      notify: (title, body) => services.notifier.show(
        '${services.settings.value.companionName}: $title',
        body,
      ),
      focused: () async => await services.background?.windowFocused() ?? true,
      onChanged: services.scheduleChanged,
    )..start();
  }

  @override
  void dispose() {
    _scheduler?.stop();
    _chat?.dispose();
    super.dispose();
  }

  void _openDay(DateTime day) {
    setState(() => _tab = AppTab.chat);
    _chat!.showDay(day);
  }

  Widget _screen(AppTab tab) => switch (tab) {
    AppTab.chat => ChatScreen(chat: _chat!),
    AppTab.memory => const MemoryScreen(),
    AppTab.plans => const ScheduleScreen(),
    AppTab.skills => const SkillsScreen(),
    AppTab.images => const ImagesScreen(),
    AppTab.settings => SettingsScreen(
      key: ValueKey(_settingsTab),
      initialTab: _settingsTab,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 280,
              child: CompanionCard(chat: _chat!, onOpenDay: _openDay),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: GlassPanel(
                blur: GlassPanel.still,
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 20, 6),
                      child: Row(
                        children: [
                          _TabBar(
                            current: _tab,
                            onSelect: (t) => setState(() => _tab = t),
                          ),
                          const SizedBox(width: 12),
                          // Shrinks instead of overflowing on narrow windows.
                          // The rest of the bar is kept free for what comes.
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: ListenableBuilder(
                                  listenable: AppScope.of(context).settings,
                                  builder: (context, _) => Row(
                                    children: [
                                      const UpdatePill(),
                                      if (_tab == AppTab.chat &&
                                          AppScope.of(
                                                context,
                                              ).settings.value.statusLight ==
                                              StatusLight.header)
                                        const RuntimeStatus(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, 0.02),
                              end: Offset.zero,
                            ).animate(anim),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(_tab),
                          child: _screen(_tab),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill tabs with a sliding highlight.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});

  final AppTab current;
  final ValueChanged<AppTab> onSelect;

  static const _width = 124.0;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.palette.tile,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutBack,
            left: current.index * _width,
            top: 0,
            bottom: 0,
            width: _width,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: context.highlight.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in AppTab.values)
                SizedBox(
                  width: _width,
                  height: 38,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onSelect(t),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          t.icon,
                          size: 18,
                          color: t == current
                              ? context.palette.text
                              : context.palette.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          t.label,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: t == current
                                ? context.palette.text
                                : context.palette.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
