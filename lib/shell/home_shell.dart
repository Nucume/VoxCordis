import 'dart:math' as math;

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
import '../services/system/desktop_notifier.dart';
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

  /// Below this window width the companion card folds into a menu button
  /// left of the tabs, and that button brings it back over the panel.
  static const roomForCard = 1140.0;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with TickerProviderStateMixin
    implements WhatsNewHost {
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
  void openSettings({int tab = 0}) => _go(AppTab.settings, settingsTab: tab);

  /// The Settings page to open on. Only a shortcut (the Images screen's
  /// settings button, a What's new action) picks another one; the tab bar
  /// always opens on General.
  int _settingsTab = 0;

  /// Tabs opened so far. They stay built (hidden) after that, so coming
  /// back is instant and keeps their place, instead of building the whole
  /// screen again and reloading its pictures. Settings is the exception:
  /// it starts afresh from the saved settings each time.
  final _opened = <AppTab>{AppTab.chat};
  final _settings = GlobalKey<SettingsScreenState>();

  /// Moves to [tab], first asking what to do with unsaved changes when
  /// leaving Settings. False when the human chose to stay.
  Future<bool> _go(AppTab tab, {int settingsTab = 0}) async {
    if (tab == _tab) return true;
    if (_tab == AppTab.settings) {
      final leave = await _settings.currentState?.mayLeave() ?? true;
      if (!leave || !mounted) return false;
    }
    setState(() {
      _tab = tab;
      _settingsTab = settingsTab;
      _opened.add(tab);
    });
    return true;
  }

  /// Before switching or adding a companion, which rebuilds the window:
  /// unsaved Settings changes get Save, Discard or Cancel.
  Future<bool> _mayLeaveSettings() async {
    if (_tab != AppTab.settings) return true;
    return await _settings.currentState?.mayLeave() ?? true;
  }

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
    DesktopNotifier.onOpen = () => services.background?.showWindow().ignore();
    _scheduler ??= Scheduler(
      repo: () => services.schedules,
      run: (item, {required late}) => _chat!.runScheduled(item, late: late),
      runsPerDay: () => services.settings.value.automationRunsPerDay,
      notify: (title, body) => services.notifier.show(
        '${services.settings.value.companionName}: $title',
        body,
        image: services.settings.value.portraitPath,
      ),
      focused: () async => await services.background?.windowFocused() ?? true,
      onChanged: services.scheduleChanged,
      idle: () => _chat!.poke(),
    )..start();
  }

  @override
  void dispose() {
    _slide.dispose();
    _pop.dispose();
    _fold.dispose();
    _open.dispose();
    _scheduler?.stop();
    _chat?.dispose();
    super.dispose();
  }

  Future<void> _openDay(DateTime day) async {
    if (_open.value > 0) _toggleCard(open: false);
    if (await _go(AppTab.chat)) _chat!.showDay(day);
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
      key: _settings,
      initialTab: _settingsTab,
      replying: () => _chat?.busy ?? false,
    ),
  };

  /// The card's width, and the room it takes with the gap after it.
  static const _cardWidth = 280.0;
  static const _shift = _cardWidth + 14;

  /// Where the menu button sits, inside the window's 14 px margin: the
  /// panel's own padding in from its corner.
  static const _button = Rect.fromLTWH(16, 14, 46, 46);

  /// The tabs move over by this much to leave the button its room.
  static const _tabShift = _shift - 46 - 8;

  /// 0 with the card in its place beside the panel, 1 with it folded into
  /// the menu button.
  late final _fold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  )..addStatusListener((_) => setState(() {}));

  /// The fold, eased, for the panel and the tabs sliding over. Made once:
  /// each one listens to [_fold] until it is disposed.
  late final _slide = CurvedAnimation(
    parent: _fold,
    curve: Curves.easeOutCubic,
  );

  /// The menu button popping in as the card arrives in it.
  late final _pop = CurvedAnimation(
    parent: _fold,
    curve: const Interval(0.72, 1, curve: Curves.easeOutBack),
  );

  /// 0 closed, 1 with the card open over the panel in a narrow window.
  late final _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  /// What the last build asked for, so the fold starts only once.
  bool? _folded;

  /// Folds or unfolds the card when the window crosses [HomeShell.roomForCard].
  void _follow(bool compact) {
    if (_folded == compact) return;
    final first = _folded == null;
    _folded = compact;
    if (first || MediaQuery.disableAnimationsOf(context)) {
      _fold.value = compact ? 1 : 0;
      if (!compact) _open.value = 0;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _folded != compact) return;
      if (compact) {
        _fold.forward();
      } else {
        // Back in its place; an open card stays where it is meanwhile.
        _fold.reverse().whenCompleteOrCancel(() {
          if (mounted && _folded == false) _open.value = 0;
        });
      }
    });
  }

  void _toggleCard({bool? open}) {
    final opening = open ?? _open.value < 0.5;
    if (MediaQuery.disableAnimationsOf(context)) {
      _open.value = opening ? 1 : 0;
    } else if (opening) {
      _open.forward();
    } else {
      _open.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < HomeShell.roomForCard;
    _follow(compact);
    // The panel takes the window's full width as soon as the card starts to
    // fold, and keeps it until the card is back. It is laid out once at that
    // size; the moving is clipping and shifting, never resizing.
    final wide = compact || _fold.value > 0 || _fold.isAnimating;
    final palette = context.palette;

    final panel = _PicturePanel(
      child: GlassPanel(
        blur: GlassPanel.still,
        padding: EdgeInsets.zero,
        // Ink and list tiles paint on this, over the glass, not under it.
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 20, 6),
                child: Row(
                  children: [
                    if (wide)
                      _MenuButton(
                        fold: _fold,
                        pop: _pop,
                        open: _open,
                        onTap: () => _toggleCard(),
                      ),
                    if (wide) const SizedBox(width: 8),
                    Expanded(
                      child: _Shifted(
                        by: wide ? _tabShift : 0,
                        animation: _slide,
                        child: LayoutBuilder(
                          builder: (context, row) => Row(
                            children: [
                              // As wide as the tabs want, up to what the row
                              // has left, below which they drop their names.
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: math.max(0, row.maxWidth - 12),
                                ),
                                child: _TabBar(current: _tab, onSelect: _go),
                              ),
                              const SizedBox(width: 12),
                              // Shrinks instead of overflowing on narrow
                              // windows. The rest of the bar is kept free for
                              // what comes.
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
                                              AppScope.of(context)
                                                      .settings
                                                      .value
                                                      .statusLight ==
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
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _Shifted(
                  // Centred content stays centred in what can be seen.
                  by: wide ? _shift / 2 : 0,
                  animation: _slide,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      for (final t in AppTab.values)
                        if (t == _tab ||
                            (t != AppTab.settings && _opened.contains(t)))
                          _TabLayer(
                            key: ValueKey(t),
                            shown: t == _tab,
                            child: _screen(t),
                          ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // How far the card has gone into the button: folded and not open.
    final gone = Listenable.merge([_fold, _open]);
    double goneBy() => _fold.value * (1 - _open.value);

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, box) {
            final cardRect = Rect.fromLTWH(0, 0, _cardWidth, box.maxHeight);
            return Stack(
              children: [
                const SizedBox.expand(),
                Positioned(
                  left: wide ? 0 : _shift,
                  top: 0,
                  right: 0,
                  bottom: 0,
                  // Always clipped, so the panel keeps its place in the tree
                  // and the tabs keep their state; it only clips when wide.
                  child: ClipRect(
                    clipper: wide ? _UncoverFromLeft(_shift, _slide) : null,
                    clipBehavior: wide ? Clip.hardEdge : Clip.none,
                    child: panel,
                  ),
                ),
                // Darkens the panel under the open card; a click on it
                // closes the card.
                AnimatedBuilder(
                  animation: gone,
                  builder: (context, _) {
                    final dim = _open.value * _fold.value;
                    if (dim == 0) return const SizedBox.shrink();
                    return Positioned.fill(
                      left: -14,
                      top: -14,
                      right: -14,
                      bottom: -14,
                      child: GestureDetector(
                        onTap: () => _toggleCard(open: false),
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.42 * dim),
                        ),
                      ),
                    );
                  },
                ),
                // The empty glass that travels between the card and the
                // button, under the card's fading contents.
                AnimatedBuilder(
                  animation: gone,
                  builder: (context, _) {
                    final g = goneBy();
                    final over = _open.value * _fold.value;
                    if (g == 0 && over == 0) return const SizedBox.shrink();
                    final t = Curves.easeInOutCubic.transform(g);
                    final r = Rect.lerp(cardRect, _button, t)!;
                    return Positioned.fromRect(
                      rect: r,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: g < 0.8 ? 1 : (1 - g) / 0.2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                22 + (16 - 22) * t,
                              ),
                              // Solid behind the card open over the panel,
                              // see-through like the card in its place.
                              color: palette.background.withValues(
                                alpha: 0.94 * over,
                              ),
                              border: Border.all(color: palette.glassBorder),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: 0.5 * over,
                                  ),
                                  blurRadius: 24,
                                ),
                              ],
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  22 + (16 - 22) * t,
                                ),
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    for (final c in palette.glassSheen)
                                      Color.alphaBlend(c, palette.glass),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // The card itself, in one place the whole time: its contents
                // fade out before the glass moves and back in after.
                Positioned.fromRect(
                  rect: cardRect,
                  child: AnimatedBuilder(
                    animation: gone,
                    child: RepaintBoundary(
                      child: CompanionCard(
                        chat: _chat!,
                        onOpenDay: _openDay,
                        mayLeave: _mayLeaveSettings,
                      ),
                    ),
                    builder: (context, card) {
                      final g = goneBy();
                      final shown = 1 - (g / 0.4).clamp(0.0, 1.0);
                      return Offstage(
                        offstage: shown == 0,
                        child: IgnorePointer(
                          ignoring: shown < 1,
                          child: Opacity(
                            opacity: Curves.easeOut.transform(shown),
                            child: card,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Shifts [child] right by [by] times what is left of [animation], so it
/// slides into its place without being laid out again.
class _Shifted extends AnimatedWidget {
  const _Shifted({
    required this.by,
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  final double by;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final v = (listenable as Animation<double>).value;
    // Always a Transform, even at zero: taking it away would build the
    // tabs underneath afresh.
    return Transform.translate(offset: Offset(by * (1 - v), 0), child: child);
  }
}

/// Hides the panel's first [width] pixels at the start of [animation] and
/// none at its end: the panel seems to grow from the left.
class _UncoverFromLeft extends CustomClipper<Rect> {
  _UncoverFromLeft(this.width, this.animation) : super(reclip: animation);

  final double width;
  final Animation<double> animation;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(width * (1 - animation.value), 0, size.width, size.height);

  @override
  bool shouldReclip(_UncoverFromLeft old) =>
      old.width != width || old.animation != animation;
}

/// The button left of the tabs, in a narrow window, that brings the
/// companion card over the panel and puts it away again. It pops in as the
/// card arrives in it.
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.fold,
    required this.pop,
    required this.open,
    required this.onTap,
  });

  final Animation<double> fold;

  /// [fold] curved for popping in; the shell makes and disposes it.
  final Animation<double> pop;
  final Animation<double> open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AnimatedBuilder(
      animation: Listenable.merge([fold, open]),
      builder: (context, child) {
        final p = pop.value;
        final isOpen = open.value > 0.5;
        return IgnorePointer(
          ignoring: fold.value < 1,
          child: Opacity(
            opacity: p.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.5 + 0.5 * p,
              child: Tooltip(
                message: isOpen
                    ? 'Hide the companion card'
                    : 'Show the companion card',
                child: Material(
                  color: palette.tile,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: onTap,
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          isOpen ? Icons.menu_open_rounded : Icons.menu_rounded,
                          key: ValueKey(isOpen),
                          size: 20,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One tab's screen in the stack. Hidden ones are neither painted nor
/// animated, and keep their state; the one coming forward fades in alone,
/// so only a single screen is drawn during the switch.
class _TabLayer extends StatefulWidget {
  const _TabLayer({super.key, required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  State<_TabLayer> createState() => _TabLayerState();
}

class _TabLayerState extends State<_TabLayer>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();
  late final _opacity = CurvedAnimation(
    parent: _fade,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(_TabLayer old) {
    super.didUpdateWidget(old);
    if (widget.shown && !old.shown) _fade.forward(from: 0);
  }

  @override
  void dispose() {
    _opacity.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !widget.shown,
    child: TickerMode(
      enabled: widget.shown,
      // Typing never lands in a hidden screen's text box.
      child: ExcludeFocus(
        excluding: !widget.shown,
        child: FadeTransition(opacity: _opacity, child: widget.child),
      ),
    ),
  );
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
        final theme = Theme.of(context);
        final palette = context.palette;
        // The same shape with or without a picture: a panel moved to
        // another place in the tree would build every tab afresh, and the
        // chat would lose where it was scrolled to.
        return Stack(
          fit: StackFit.expand,
          children: [
            if (picture == null)
              const SizedBox.shrink()
            else
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
              data: picture == null
                  ? theme
                  : theme.copyWith(extensions: [palette.seeThrough()]),
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
                            Flexible(
                              child: Text(
                                t.label,
                                maxLines: 1,
                                overflow: TextOverflow.fade,
                                softWrap: false,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: t == current
                                      ? context.palette.text
                                      : context.palette.textMuted,
                                ),
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
