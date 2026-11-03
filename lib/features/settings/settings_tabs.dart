import 'package:flutter/material.dart';

import '../../data/settings.dart';
import '../../theme/app_theme.dart';

/// One page of Settings, as its tab shows it.
typedef SettingsPage = ({String label, IconData icon});

/// The pages of Settings in a glass bar: pills with icons across the top, or
/// a rail down the left ([SettingsTabs]). The open page sits in an accent
/// pill that slides to the one picked.
class SettingsTabBar extends StatelessWidget {
  const SettingsTabBar({super.key, required this.pages, required this.layout});

  final List<SettingsPage> pages;
  final SettingsTabs layout;

  /// The rail's width, and the height of a row in it.
  static const railWidth = 200.0;
  static const _railRow = 40.0;
  static const _railGap = 2.0;
  static const _pad = 5.0;

  static BoxDecoration _glass(
    BuildContext context,
    double radius, {
    bool sheen = true,
  }) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: palette.glass,
      border: Border.all(color: palette.glassBorder),
      // Across a long thin bar the sheen reads as a stripe.
      gradient: !sheen
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent.withValues(alpha: 0.10), ...palette.glassSheen],
            ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark
                ? 0.25
                : 0.06,
          ),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    );
  }

  /// The accent pill under the open page.
  static BoxDecoration _pill(BuildContext context, double radius) {
    final accent = Theme.of(context).colorScheme.primary;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: accent.withValues(alpha: 0.2),
      border: Border.all(color: accent.withValues(alpha: 0.5)),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.3),
          blurRadius: 16,
          spreadRadius: -4,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      layout == SettingsTabs.side ? _rail(context) : _top(context);

  Widget _top(BuildContext context) {
    final palette = context.palette;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(_pad),
        decoration: _glass(context, 999, sheen: false),
        child: _ArrowsWhenCut(
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: _pill(context, 999),
            labelPadding: const EdgeInsets.symmetric(horizontal: 14),
            labelColor: palette.text,
            unselectedLabelColor: palette.textMuted,
            labelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(fontSize: 14),
            splashBorderRadius: BorderRadius.circular(999),
            overlayColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.hovered) ? palette.tile : null,
            ),
            tabs: [
              for (final p in pages)
                Tab(
                  height: 34,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(p.icon, size: 17),
                      const SizedBox(width: 8),
                      Text(p.label),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rail(BuildContext context) {
    final controller = DefaultTabController.of(context);
    const step = _railRow + _railGap;
    return Container(
      width: railWidth,
      decoration: _glass(context, 20),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(_pad + 3),
        child: Stack(
          children: [
            // Follows the page as it moves, so a swipe or a click glides.
            AnimatedBuilder(
              animation: controller.animation!,
              builder: (context, _) => Positioned(
                left: 0,
                right: 0,
                top: controller.animation!.value * step,
                height: _railRow,
                child: DecoratedBox(decoration: _pill(context, 12)),
              ),
            ),
            Column(
              children: [
                for (var i = 0; i < pages.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == pages.length - 1 ? 0 : _railGap,
                    ),
                    child: _RailRow(
                      page: pages[i],
                      index: i,
                      controller: controller,
                      height: _railRow,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RailRow extends StatefulWidget {
  const _RailRow({
    required this.page,
    required this.index,
    required this.controller,
    required this.height,
  });

  final SettingsPage page;
  final int index;
  final TabController controller;
  final double height;

  @override
  State<_RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<_RailRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final open = widget.controller.index == widget.index;
        return Semantics(
          selected: open,
          button: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.controller.animateTo(widget.index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: widget.height,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: _hover && !open ? palette.tile : Colors.transparent,
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.page.icon,
                      size: 18,
                      color: open ? palette.text : palette.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.page.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: open ? FontWeight.w600 : FontWeight.w400,
                          color: open ? palette.text : palette.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Arrows at the ends of a scrolling tab bar that doesn't fit, each shown
/// while there is more to see on its side. A click moves most of a width.
class _ArrowsWhenCut extends StatefulWidget {
  const _ArrowsWhenCut({required this.child});

  final Widget child;

  @override
  State<_ArrowsWhenCut> createState() => _ArrowsWhenCutState();
}

class _ArrowsWhenCutState extends State<_ArrowsWhenCut> {
  bool _left = false;
  bool _right = false;

  /// The tab bar's own scroll view.
  ScrollPosition? _position;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  /// Looks again after this frame, once the bar has its size.
  void _check() {
    if (_checking) return;
    _checking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checking = false;
      if (!mounted) return;
      final p = _position ?? _find();
      if (p == null || !p.hasContentDimensions || !p.hasPixels) return;
      final left = p.pixels > p.minScrollExtent + 1;
      final right = p.pixels < p.maxScrollExtent - 1;
      if (left != _left || right != _right) {
        setState(() {
          _left = left;
          _right = right;
        });
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  ScrollPosition? _find() {
    ScrollableState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        found = e.state as ScrollableState;
        return;
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
    _position = found?.position?..addListener(_check);
    return _position;
  }

  void _move(int direction) {
    final p = _position;
    if (p == null) return;
    final to = (p.pixels + direction * p.viewportDimension * 0.7).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    p.animateTo(
      to,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // A new size (the window, the page) can cut the bar or uncut it.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _check();
        return false;
      },
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          _check();
          return false;
        },
        child: SizeChangedLayoutNotifier(
          child: Stack(
            children: [
              widget.child,
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _Arrow(
                  shown: _left,
                  icon: Icons.chevron_left_rounded,
                  tooltip: 'More settings to the left',
                  onTap: () => _move(-1),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _Arrow(
                  shown: _right,
                  icon: Icons.chevron_right_rounded,
                  tooltip: 'More settings to the right',
                  onTap: () => _move(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.shown,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final bool shown;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: AnimatedScale(
          scale: shown ? 1 : 0.6,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: Center(
            child: Tooltip(
              message: tooltip,
              child: Material(
                // Solid enough that the tab under it doesn't show through.
                color: Color.alphaBlend(
                  accent.withValues(alpha: 0.18),
                  palette.background,
                ),
                shape: CircleBorder(
                  side: BorderSide(color: accent.withValues(alpha: 0.45)),
                ),
                elevation: 4,
                shadowColor: Colors.black54,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(icon, size: 20, color: palette.text),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
