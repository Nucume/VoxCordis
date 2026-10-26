import 'dart:ui';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The frosted panel the companion menu and every picker open in: it fades
/// in, settles from a little smaller and unfolds from its [alignment] edge.
class GlassPopoverPanel extends StatelessWidget {
  const GlassPopoverPanel({
    super.key,
    required this.animation,
    required this.child,
    this.width,
    this.radius = 20,
    this.alignment = Alignment.topCenter,
  });

  final Animation<double> animation;
  final Widget child;
  final double? width;
  final double radius;

  /// Where it grows from: the top edge when it opens downwards.
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final r = BorderRadius.circular(radius);
    final unfold = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.5),
      ),
      child: ScaleTransition(
        alignment: alignment,
        scale: Tween(begin: 0.92, end: 1.0).animate(unfold),
        child: Container(
          width: width,
          decoration: BoxDecoration(
            borderRadius: r,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.35
                      : 0.1,
                ),
                blurRadius: 30,
                offset: const Offset(0, 14),
              ),
              BoxShadow(
                color: accent.withValues(alpha: 0.18),
                blurRadius: 40,
                spreadRadius: -6,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: r,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: r,
                  color: palette.glass,
                  border: Border.all(color: palette.glassBorder),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: 0.14),
                      ...palette.glassSheen,
                    ],
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: SizeTransition(
                    sizeFactor: CurvedAnimation(
                      parent: animation,
                      curve: const Interval(0, 0.7, curve: Curves.easeOutCubic),
                      reverseCurve: Curves.easeInCubic,
                    ),
                    alignment: alignment,
                    child: child,
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

/// [child] arriving a little after the row above it, as row [index].
Widget glassStagger(Animation<double> animation, int index, Widget child) {
  final start = (0.15 + index * 0.06).clamp(0.0, 0.55);
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

/// One choice in a [GlassSelect].
class GlassOption<T> {
  const GlassOption(this.value, this.label, {this.leading});

  final T value;
  final String label;

  /// Shown before the label, e.g. a colour orb.
  final Widget? leading;
}

/// A picker that opens the same glass menu as the companion switcher, a
/// little more compact: the chosen option sits tinted with the accent, and
/// the rest lift under the pointer.
class GlassSelect<T> extends StatefulWidget {
  const GlassSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.label,
    this.width,
    this.minWidth,
  });

  final T value;
  final List<GlassOption<T>> options;
  final ValueChanged<T>? onChanged;

  /// A small caption above the button, like a field label.
  final String? label;

  /// The button's width; it fits its widest option when null.
  final double? width;

  /// The least it gets when it fits its option, so pickers stacked in a
  /// column line up whatever they show.
  final double? minWidth;

  @override
  State<GlassSelect<T>> createState() => _GlassSelectState<T>();
}

class _GlassSelectState<T> extends State<GlassSelect<T>>
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _anchor = GlobalKey();
  final _tapGroup = Object();
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 160),
  );

  static const _rowHeight = 38.0;
  static const _padding = 6.0;

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
    setState(() {});
    await _anim.reverse();
    if (mounted) setState(_portal.hide);
  }

  Future<void> _pick(T value) async {
    await _close();
    if (value != widget.value) widget.onChanged?.call(value);
  }

  GlassOption<T>? get _current {
    for (final o in widget.options) {
      if (o.value == widget.value) return o;
    }
    return null;
  }

  Widget _menu(BuildContext context) {
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    final screen = MediaQuery.sizeOf(context);
    final top = box?.localToGlobal(Offset.zero).dy ?? 0;
    final height = box?.size.height ?? 36;
    final full = widget.options.length * _rowHeight + _padding * 2;
    final below = screen.height - top - height - 16;
    final above = top - 16;
    // Downwards unless it fits better above.
    final down = below >= full || below >= above;
    final room = (down ? below : above) - 6;
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: down ? Alignment.bottomLeft : Alignment.topLeft,
        followerAnchor: down ? Alignment.topLeft : Alignment.bottomLeft,
        offset: Offset(-_padding, down ? 6 : -6),
        child: TapRegion(
          groupId: _tapGroup,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _close,
            },
            child: Focus(
              autofocus: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: (box?.size.width ?? 0) + _padding * 2,
                  maxHeight: room.clamp(_rowHeight * 2, full),
                ),
                child: IntrinsicWidth(
                  child: GlassPopoverPanel(
                    animation: _anim,
                    radius: 16,
                    alignment: down
                        ? Alignment.topCenter
                        : Alignment.bottomCenter,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(_padding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < widget.options.length; i++)
                            glassStagger(
                              _anim,
                              i,
                              _OptionRow(
                                option: widget.options[i],
                                selected:
                                    widget.options[i].value == widget.value,
                                height: _rowHeight,
                                onTap: () => _pick(widget.options[i].value),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final current = _current;
    final enabled = widget.onChanged != null;
    final button = TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _menu,
          child: _Hover(
            onTap: enabled ? _toggle : null,
            builder: (context, hover) => AnimatedContainer(
              key: _anchor,
              duration: const Duration(milliseconds: 160),
              width: widget.width,
              height: 36,
              constraints: widget.minWidth == null
                  ? null
                  : BoxConstraints(minWidth: widget.minWidth!),
              padding: const EdgeInsets.only(left: 10, right: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: hover || _open ? palette.tile : Colors.transparent,
                border: Border.all(
                  color: _open
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.5)
                      : palette.glassBorder,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                // Past [minWidth], the option stays left and the arrow right.
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    fit: widget.width == null ? FlexFit.loose : FlexFit.tight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (current?.leading case final leading?) ...[
                          leading,
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            current?.label ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: enabled ? palette.text : palette.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 20,
                      color: palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final label = widget.label;
    if (label == null) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
        ),
        button,
      ],
    );
  }
}

class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.selected,
    required this.height,
    required this.onTap,
  });

  final GlassOption<T> option;
  final bool selected;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return _Hover(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: height - 2,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected
              ? accent.withValues(alpha: 0.16)
              : hover
              ? palette.tile
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.45)
                : hover
                ? palette.glassBorder
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            if (option.leading case final leading?) ...[
              leading,
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: palette.text,
                ),
              ),
            ),
            const SizedBox(width: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: selected
                  ? Icon(
                      Icons.check_rounded,
                      key: const ValueKey('on'),
                      size: 16,
                      color: accent,
                    )
                  : const SizedBox(key: ValueKey('off'), width: 16),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lifts a little and reports hover, like the companion menu's rows.
class _Hover extends StatefulWidget {
  const _Hover({required this.onTap, required this.builder});

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool hover) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
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
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: on ? 1.015 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: widget.builder(context, on),
        ),
      ),
    );
  }
}
