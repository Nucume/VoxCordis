import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/desk/pictures.dart';
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
  images('Images', Icons.image_outlined),
  memory('Memory', Icons.auto_awesome_outlined),
  skills('Skills', Icons.school_outlined),
  plans('Plans', Icons.alarm_rounded),
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
    // Pictures the companion draws show up in the chat when done.
    services.imageEngine.onDrawn = (job, picture) =>
        _chat!.addPicture(job, picture);
    services.imageEngine.onFailed = (job, error) => _chat!.pictureFailed(error);
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
      idle: () => _chat!.poke(),
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
    AppTab.images => ImagesScreen(
      onSettings: () => openSettings(tab: SettingsScreen.imagesTab),
    ),
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
              child: _PicturePanel(
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
                            Flexible(
                              flex: 0,
                              child: _TabBar(
                                current: _tab,
                                onSelect: (t) => setState(() => _tab = t),
                              ),
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
            ),
          ],
        ),
      ),
    );
  }
}

/// The main panel over the companion's background picture, when it has
/// one: only this panel shows it, darkened by the Darkness slider, while
/// the card and the window keep the colorway. Its glass lets more of the
/// picture through.
class _PicturePanel extends StatelessWidget {
  const _PicturePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        services.settings,
        services.backgroundRevision,
      ]),
      builder: (context, _) {
        final s = services.settings.value;
        final folder = s.companionFolder;
        final picture = folder == null ? null : Pictures.backgroundIn(folder);
        if (picture == null) return child;
        final theme = Theme.of(context);
        final palette = context.palette;
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: RepaintBoundary(
                child: ColoredBox(
                  color: palette.background,
                  child: Image.file(
                    picture,
                    // A new picture under the same name is loaded afresh.
                    key: ValueKey(picture.statSync().modified),
                    fit: BoxFit.cover,
                    // Decoded once at about panel size, not at full size.
                    cacheWidth: 2048,
                    color: palette.background.withValues(
                      alpha: s.backgroundDim,
                    ),
                    colorBlendMode: BlendMode.srcATop,
                    errorBuilder: (_, _, _) => const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            Theme(
              data: theme.copyWith(extensions: [palette.seeThrough()]),
              child: child,
            ),
          ],
        );
      },
    );
  }
}

/// Pill tabs with a sliding highlight. They narrow with the window, and
/// below [_labelWidth] show only their icons (the name as a tooltip).
class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});

  final AppTab current;
  final ValueChanged<AppTab> onSelect;

  static const _maxWidth = 124.0;
  static const _labelWidth = 104.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = ((constraints.maxWidth - 8) / AppTab.values.length).clamp(
        44.0,
        _maxWidth,
      );
      return _bar(context, width, labels: width >= _labelWidth);
    },
  );

  Widget _bar(BuildContext context, double width, {required bool labels}) {
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
            left: current.index * width,
            top: 0,
            bottom: 0,
            width: width,
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
                  width: width,
                  height: 38,
                  child: Tooltip(
                    message: labels ? '' : t.label,
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
                          if (labels) ...[
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
                        ],
                      ),
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
