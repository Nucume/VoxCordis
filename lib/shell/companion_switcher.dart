import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../data/desk/pictures.dart';
import '../data/settings.dart';
import '../features/chat/chat_controller.dart';
import '../features/export/export_dialog.dart';
import '../theme/app_theme.dart';
import '../theme/glass_popover.dart';

/// Wraps the portrait and name on the companion card: a tap drops a glass
/// panel of every companion, to switch to, and "Add another companion".
///
/// VoxCordis is built around one companion. The first time someone adds a
/// second, they are told so before setup opens.
class CompanionSwitcher extends StatefulWidget {
  const CompanionSwitcher({
    super.key,
    required this.chat,
    required this.builder,
  });

  final ChatController chat;

  /// The portrait and name; [open] turns the little chevron.
  final Widget Function(BuildContext context, bool open) builder;

  /// The picture the companion chose, else the one from its setup.
  static String? avatarOf(CompanionProfile c) =>
      Pictures.avatarIn(c.folder)?.path ?? c.portraitPath;

  /// How many of [count] companions the menu lists in [maxHeight] of room;
  /// the rest are behind "More…".
  static int fitting(int count, double maxHeight) =>
      _Popover.fitting(count, maxHeight);

  @override
  State<CompanionSwitcher> createState() => _CompanionSwitcherState();
}

class _CompanionSwitcherState extends State<CompanionSwitcher>
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _anchor = GlobalKey();
  final _tapGroup = Object();
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 200),
  );

  bool get _open =>
      _portal.isShowing && _anim.status != AnimationStatus.reverse;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _toggle() => _open ? _close() : _show();

  void _show() {
    setState(_portal.show);
    _anim.forward(from: 0);
  }

  Future<void> _close() async {
    if (!_portal.isShowing) return;
    setState(() {}); // turns the chevron back at once
    await _anim.reverse();
    if (mounted) setState(_portal.hide);
  }

  /// Switching mid-reply would write the reply into the wrong chat.
  bool _waitForReply() {
    if (!widget.chat.busy) return false;
    final name = AppScope.of(context).settings.value.companionName;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Let $name finish replying first.')));
    return true;
  }

  Future<void> _switchTo(CompanionProfile c) async {
    if (_waitForReply()) return;
    final services = AppScope.of(context);
    await _close();
    await services.switchCompanion(services.settings.value.switchedTo(c));
  }

  Future<void> _add() async {
    if (_waitForReply()) return;
    final services = AppScope.of(context);
    final s = services.settings.value;
    await _close();
    if (!s.toldAboutMoreCompanions) {
      if (!mounted) return;
      final go = await showOneCompanionNotice(context, s.companionName);
      if (go != true) return;
    }
    services.addingCompanion.value = true;
    if (!s.toldAboutMoreCompanions) {
      await services.settings.update(
        services.settings.value.copyWith(toldAboutMoreCompanions: true),
      );
    }
  }

  /// The current companion to a ZIP, after it finishes replying (the
  /// reply would be missing).
  Future<void> _export() async {
    if (_waitForReply()) return;
    await _close();
    if (!mounted) return;
    await showExportDialog(context);
  }

  /// Every companion as cards, when the menu has no room for them all.
  Future<void> _more() async {
    await _close();
    if (!mounted) return;
    final s = AppScope.of(context).settings.value;
    final picked = await _showCompanionGallery(context, s);
    if (!mounted || picked == null) return;
    switch (picked) {
      case _AddPick():
        await _add();
      case _CompanionPick(:final companion):
        await _switchTo(companion);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings.value;
    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) {
            final box =
                _anchor.currentContext?.findRenderObject() as RenderBox?;
            final width = box?.size.width ?? 244;
            // Room below the name, down to a margin above the window edge.
            final top = box == null
                ? 0.0
                : box.localToGlobal(Offset(0, box.size.height)).dy;
            final room = MediaQuery.sizeOf(context).height - top - 8 - 16;
            return Align(
              alignment: Alignment.topLeft,
              child: CompositedTransformFollower(
                link: _link,
                targetAnchor: Alignment.bottomCenter,
                followerAnchor: Alignment.topCenter,
                offset: const Offset(0, 8),
                child: TapRegion(
                  groupId: _tapGroup,
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape): _close,
                    },
                    child: Focus(
                      autofocus: true,
                      child: _Popover(
                        animation: _anim,
                        width: width + 12,
                        maxHeight: room,
                        settings: s,
                        onSwitch: _switchTo,
                        onAdd: _add,
                        onExport: _export,
                        onMore: _more,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
          child: Tooltip(
            message: s.otherCompanions.isEmpty
                ? 'Companions'
                : 'Switch companion',
            waitDuration: const Duration(milliseconds: 800),
            child: InkWell(
              key: _anchor,
              borderRadius: BorderRadius.circular(16),
              onTap: _toggle,
              child: widget.builder(context, _open),
            ),
          ),
        ),
      ),
    );
  }
}

/// The glass panel itself: it unfolds from under the name, and its rows
/// follow one after another.
class _Popover extends StatelessWidget {
  const _Popover({
    required this.animation,
    required this.width,
    required this.maxHeight,
    required this.settings,
    required this.onSwitch,
    required this.onAdd,
    required this.onExport,
    required this.onMore,
  });

  final Animation<double> animation;
  final double width;

  /// The room below the name: rows that don't fit go behind "More…".
  final double maxHeight;
  final AppSettings settings;
  final ValueChanged<CompanionProfile> onSwitch;
  final VoidCallback onAdd;
  final VoidCallback onExport;
  final VoidCallback onMore;

  /// Heights of the parts, for working out how many rows fit.
  static const rowHeight = 60.0;
  static const fixedHeight = 184.0; // header, divider, two action rows

  /// How many companions to list when [count] exist, the rest behind
  /// "More…". The current companion is always listed.
  static int fitting(int count, double maxHeight) {
    final rows = ((maxHeight - fixedHeight) / rowHeight).floor();
    if (count <= rows) return count;
    return (rows - 1).clamp(1, count); // one row goes to "More…"
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final all = settings.companions;
    final shown = fitting(all.length, maxHeight);
    final companions = all.take(shown).toList();
    final hidden = all.length - shown;
    final rows = companions.length + (hidden > 0 ? 2 : 1);

    // Each row starts a little after the one above it.
    Widget staggered(int i, Widget child) {
      final start = (0.15 + i * 0.1).clamp(0.0, 0.7);
      final a = CurvedAnimation(
        parent: animation,
        curve: Interval(
          start,
          (start + 0.45).clamp(0.0, 1.0),
          curve: Curves.easeOutCubic,
        ),
      );
      return FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -0.25),
            end: Offset.zero,
          ).animate(a),
          child: child,
        ),
      );
    }

    return GlassPopoverPanel(
      animation: animation,
      width: width,
      // The panel grows downwards out of the name.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            staggered(
              0,
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  all.length == 1 ? 'YOUR COMPANION' : 'YOUR COMPANIONS',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.4,
                    color: palette.textMuted,
                  ),
                ),
              ),
            ),
            for (var i = 0; i < companions.length; i++)
              staggered(
                i + 1,
                _CompanionRow(
                  companion: companions[i],
                  current: i == 0,
                  onTap: i == 0 ? null : () => onSwitch(companions[i]),
                ),
              ),
            if (hidden > 0)
              staggered(
                companions.length + 1,
                _MoreRow(hidden: hidden, onTap: onMore),
              ),
            staggered(
              rows,
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Divider(height: 1, color: palette.glassBorder),
              ),
            ),
            staggered(
              rows,
              _ActionRow(
                icon: Icons.add_rounded,
                label: 'Add another companion',
                turns: 0.25,
                onTap: onAdd,
              ),
            ),
            staggered(
              rows + 1,
              _ActionRow(
                icon: Icons.ios_share_rounded,
                label: 'Export ${settings.companionName}…',
                onTap: onExport,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row that lifts and tints when the pointer is over it.
class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.onTap, required this.builder});

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool hover) builder;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = _hover && widget.onTap != null;
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: on ? 1.02 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: widget.builder(context, on),
        ),
      ),
    );
  }
}

class _CompanionRow extends StatelessWidget {
  const _CompanionRow({
    required this.companion,
    required this.current,
    required this.onTap,
  });

  final CompanionProfile companion;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // Each companion wears its own colour here, not the current one's.
    final colour = Color(companion.accentColor);
    final traits = companion.traits.take(3).join(' · ');
    return _HoverRow(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: current
              ? colour.withValues(alpha: 0.16)
              : hover
              ? palette.tile
              : Colors.transparent,
          border: Border.all(
            color: current
                ? colour.withValues(alpha: 0.45)
                : hover
                ? palette.glassBorder
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            _MiniPortrait(
              path: CompanionSwitcher.avatarOf(companion),
              ring: colour,
              glow: current || hover,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    companion.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                      color: palette.text,
                    ),
                  ),
                  if (traits.isNotEmpty || current) ...[
                    const SizedBox(height: 2),
                    Text(
                      current ? 'With you now' : traits,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: palette.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: current
                  ? Icon(
                      Icons.favorite_rounded,
                      key: const ValueKey('current'),
                      size: 16,
                      color: colour,
                    )
                  : hover
                  ? Icon(
                      Icons.arrow_forward_rounded,
                      key: const ValueKey('go'),
                      size: 16,
                      color: palette.textMuted,
                    )
                  : const SizedBox(key: ValueKey('none'), width: 16),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Add another companion" and "Export …": an icon tile and a label.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.turns = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// How far the icon turns under the pointer.
  final double turns;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return _HoverRow(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: hover ? accent.withValues(alpha: 0.12) : Colors.transparent,
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: accent.withValues(alpha: hover ? 0.3 : 0.14),
                border: Border.all(
                  color: accent.withValues(alpha: hover ? 0.8 : 0.4),
                ),
              ),
              child: AnimatedRotation(
                turns: hover ? turns : 0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: AnimatedScale(
                  scale: hover && turns == 0 ? 1.1 : 1,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: Icon(icon, color: palette.text, size: 22),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small rounded picture with a rim in the companion's colour, or the
/// heart without one. (The card's Portrait fills its width.)
class _MiniPortrait extends StatelessWidget {
  const _MiniPortrait({
    this.path,
    required this.ring,
    this.glow = false,
    this.size = 40,
  });

  final String? path;
  final Color ring;
  final bool glow;
  final double size;

  @override
  Widget build(BuildContext context) {
    final file = path == null ? null : File(path!);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: size,
      height: size,
      padding: EdgeInsets.all(size > 60 ? 3 : 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ring, ring.withValues(alpha: 0.35)],
        ),
        boxShadow: [
          BoxShadow(
            color: ring.withValues(alpha: glow ? 0.45 : 0),
            blurRadius: size > 60 ? 24 : 12,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.3 - 2),
        child: ColoredBox(
          color: const Color(0xFF0B1020),
          child: file != null && file.existsSync()
              ? Image.file(
                  file,
                  fit: BoxFit.cover,
                  cacheWidth: (size * 3).round(),
                )
              : Padding(
                  padding: EdgeInsets.all(size * 0.13),
                  child: Image.asset(AppTheme.heartMark),
                ),
        ),
      ),
    );
  }
}

/// Shown once, the first time a second companion is added: a glass card
/// that pops in over a blurred window.
Future<bool?> showOneCompanionNotice(BuildContext context, String name) =>
    showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 380),
      pageBuilder: (context, _, _) => _OneCompanionNotice(name: name),
      transitionBuilder: (context, a, _, child) {
        final curved = CurvedAnimation(
          parent: a,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeInCubic,
        );
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6 * a.value, sigmaY: 6 * a.value),
          child: FadeTransition(
            opacity: a,
            child: ScaleTransition(
              scale: Tween(begin: 0.9, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );

class _OneCompanionNotice extends StatelessWidget {
  const _OneCompanionNotice({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Material(
            type: MaterialType.transparency,
            child: GlassPanel(
              padding: const EdgeInsets.fromLTRB(32, 30, 32, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.4, end: 1),
                    duration: const Duration(milliseconds: 1100),
                    curve: Curves.elasticOut,
                    builder: (context, scale, child) =>
                        Transform.scale(scale: scale, child: child),
                    child: const _Heartbeat(),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'VoxCordis is made for one companion',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'The idea is one companion who grows with you: one '
                    'memory, one personality, one story together. Switching '
                    'between several isn\'t what this app was built for.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.textMuted, height: 1.5),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: palette.tile,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.folder_copy_outlined,
                          size: 20,
                          color: palette.textMuted,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'You can still add another. Each one gets its '
                            'own folder, chats and memories, and nothing of '
                            '$name\'s changes. Switch back any time.',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context, false),
                        icon: const Icon(Icons.favorite_rounded, size: 18),
                        label: Text('Stay with $name'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(context, true),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add another anyway'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The heart mark, beating softly.
class _Heartbeat extends StatefulWidget {
  const _Heartbeat();

  @override
  State<_Heartbeat> createState() => _HeartbeatState();
}

class _HeartbeatState extends State<_Heartbeat>
    with SingleTickerProviderStateMixin {
  late final _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  // Two quick swells, then rest: lub-dub.
  static double _scale(double t) {
    double pulse(double at) {
      final d = (t - at).abs();
      return d > 0.1 ? 0 : (1 - d / 0.1);
    }

    return 1 + 0.08 * pulse(0.1) + 0.05 * pulse(0.3);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _beat,
      builder: (context, child) =>
          Transform.scale(scale: _scale(_beat.value), child: child),
      child: Image.asset(AppTheme.heartMark, height: 64),
    );
  }
}

/// "More…" at the foot of the list, when not every companion fits.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.hidden, required this.onTap});

  final int hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return _HoverRow(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: hover ? palette.tile : Colors.transparent,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.grid_view_rounded, color: palette.textMuted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'More…',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                  Text(
                    hidden == 1
                        ? '1 more companion'
                        : '$hidden more companions',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                ],
              ),
            ),
            AnimatedSlide(
              offset: Offset(hover ? 0.2 : 0, 0),
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: palette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the gallery hands back.
sealed class _GalleryPick {
  const _GalleryPick();
}

class _CompanionPick extends _GalleryPick {
  const _CompanionPick(this.companion);
  final CompanionProfile companion;
}

class _AddPick extends _GalleryPick {
  const _AddPick();
}

/// Every companion as a card, the last one an empty card to create a new
/// one. Opened from "More…" when the menu has no room for them all.
Future<_GalleryPick?> _showCompanionGallery(
  BuildContext context,
  AppSettings settings,
) => showGeneralDialog<_GalleryPick>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: Colors.black.withValues(alpha: 0.35),
  transitionDuration: const Duration(milliseconds: 420),
  pageBuilder: (context, animation, _) =>
      _Gallery(settings: settings, animation: animation),
  transitionBuilder: (context, a, _, child) {
    final curved = CurvedAnimation(
      parent: a,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 6 * a.value, sigmaY: 6 * a.value),
      child: FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        ),
      ),
    );
  },
);

class _Gallery extends StatelessWidget {
  const _Gallery({required this.settings, required this.animation});

  final AppSettings settings;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final companions = settings.companions;
    final screen = MediaQuery.sizeOf(context);
    return Center(
      child: SizedBox(
        width: (screen.width - 80).clamp(320.0, 920.0),
        height: (screen.height - 80).clamp(320.0, 680.0),
        child: Material(
          type: MaterialType.transparency,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.pop(context),
            },
            child: Focus(
              autofocus: true,
              child: GlassPanel(
                padding: const EdgeInsets.fromLTRB(28, 22, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Image.asset(AppTheme.heartMark, height: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Your companions',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '${companions.length}',
                          style: TextStyle(color: palette.textMuted),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.only(right: 8, bottom: 4),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                              childAspectRatio: 0.78,
                            ),
                        itemCount: companions.length + 1,
                        itemBuilder: (context, i) {
                          // Cards arrive one after another, row by row.
                          final start = (0.2 + i * 0.05).clamp(0.0, 0.8);
                          final a = CurvedAnimation(
                            parent: animation,
                            curve: Interval(
                              start,
                              (start + 0.4).clamp(0.0, 1.0),
                              curve: Curves.easeOutBack,
                            ),
                          );
                          final card = i == companions.length
                              ? _CreateCard(
                                  onTap: () =>
                                      Navigator.pop(context, const _AddPick()),
                                )
                              : _CompanionCard(
                                  companion: companions[i],
                                  current: i == 0,
                                  onTap: i == 0
                                      ? () => Navigator.pop(context)
                                      : () => Navigator.pop(
                                          context,
                                          _CompanionPick(companions[i]),
                                        ),
                                );
                          return FadeTransition(
                            opacity: a,
                            child: ScaleTransition(
                              scale: Tween(begin: 0.85, end: 1.0).animate(a),
                              child: card,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One companion in the gallery: a big picture, its name and traits.
class _CompanionCard extends StatelessWidget {
  const _CompanionCard({
    required this.companion,
    required this.current,
    required this.onTap,
  });

  final CompanionProfile companion;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colour = Color(companion.accentColor);
    return _HoverRow(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        transform: Matrix4.translationValues(0, hover ? -4 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: current
              ? colour.withValues(alpha: 0.16)
              : hover
              ? palette.tile
              : palette.tile.withValues(alpha: palette.tile.a * 0.5),
          border: Border.all(
            color: current || hover
                ? colour.withValues(alpha: 0.55)
                : palette.glassBorder,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => Center(
                  child: _MiniPortrait(
                    path: CompanionSwitcher.avatarOf(companion),
                    ring: colour,
                    glow: current || hover,
                    size: c.biggest.shortestSide,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    companion.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: palette.text,
                    ),
                  ),
                ),
                if (current) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.favorite_rounded, size: 14, color: colour),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              current ? 'With you now' : companion.traits.take(3).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last card: empty, with a dashed edge, to create a new companion.
class _CreateCard extends StatelessWidget {
  const _CreateCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return _HoverRow(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        transform: Matrix4.translationValues(0, hover ? -4 : 0, 0),
        child: CustomPaint(
          painter: _DashedBorder(
            color: hover ? accent : palette.glassBorder.withValues(alpha: 0.6),
            radius: 18,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: hover ? accent.withValues(alpha: 0.1) : Colors.transparent,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: hover ? 0.3 : 0.12),
                  ),
                  child: AnimatedRotation(
                    turns: hover ? 0.25 : 0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    child: Icon(
                      Icons.add_rounded,
                      size: 30,
                      color: palette.text,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Create a new one',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'or import a character',
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ).deflate(0.75),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 12) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.radius != radius;
}
