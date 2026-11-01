import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The LoRAs in the Draw panel as glass buttons across the panel's width.
/// Picking one tints it with the accent and fades in a strength slider under
/// its name, in room each button keeps for it, so a long list stays a few
/// rows tall and nothing shifts.
class LoraGrid extends StatelessWidget {
  const LoraGrid({
    super.key,
    required this.loras,
    required this.picked,
    required this.onChanged,
  });

  /// The strength a LoRA starts at when it is picked.
  static const start = 0.8;

  /// The narrowest a button gets before the grid drops a column.
  static const _minWidth = 220.0;
  static const _gap = 8.0;

  final List<({String name, String note})> loras;

  /// Picked LoRAs by name, with their strength.
  final Map<String, double> picked;

  /// Called with the LoRA's name and its new strength, or null when it is
  /// unpicked.
  final void Function(String name, double? weight) onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final columns = ((box.maxWidth + _gap) / (_minWidth + _gap))
            .floor()
            .clamp(1, 6);
        // Rounded down, or a rounding error can push the last one over.
        final width = ((box.maxWidth - _gap * (columns - 1)) / columns)
            .floorToDouble();
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final l in loras)
              SizedBox(
                width: width,
                child: _LoraButton(
                  key: ValueKey('lora-${l.name}'),
                  name: l.name,
                  note: l.note,
                  weight: picked[l.name],
                  onTap: () => onChanged(
                    l.name,
                    picked.containsKey(l.name) ? null : start,
                  ),
                  onWeight: (v) => onChanged(l.name, v),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LoraButton extends StatefulWidget {
  const _LoraButton({
    super.key,
    required this.name,
    required this.note,
    required this.weight,
    required this.onTap,
    required this.onWeight,
  });

  final String name;
  final String note;

  /// Null while the LoRA is not picked.
  final double? weight;
  final VoidCallback onTap;
  final ValueChanged<double> onWeight;

  @override
  State<_LoraButton> createState() => _LoraButtonState();
}

class _LoraButtonState extends State<_LoraButton> {
  bool _hover = false;

  /// The last strength shown, kept so the slider doesn't jump while it
  /// fades away.
  double _shown = LoraGrid.start;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final on = widget.weight != null;
    if (widget.weight case final w?) _shown = w;
    final header = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      color: palette.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: on
                      ? Container(
                          key: const ValueKey('on'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: accent.withValues(alpha: 0.22),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            widget.weight!.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: palette.text,
                            ),
                          ),
                        )
                      : Icon(
                          Icons.add_rounded,
                          key: const ValueKey('off'),
                          size: 18,
                          color: palette.textMuted,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final slider = Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              'Strength',
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                tickMarkShape: SliderTickMarkShape.noTickMark,
                inactiveTrackColor: palette.glassBorder,
                thumbColor: accent,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: _shown,
                min: -1,
                max: 2,
                divisions: 30,
                onChanged: on ? widget.onWeight : null,
              ),
            ),
          ),
        ],
      ),
    );
    final lit = on || _hover;
    final fill = on
        ? accent.withValues(alpha: _hover ? 0.2 : 0.15)
        : _hover
        ? Color.alphaBlend(accent.withValues(alpha: 0.07), palette.glass)
        : palette.glass;
    // Like the companion cards: a sheen across the glass, a lift and the
    // accent on the edge under the pointer, and a soft glow once picked.
    // Plain decoration, no blur, so a long list costs nothing to draw.
    final tile = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.02 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            // A gradient replaces the colour, so the fill is laid under
            // each of its stops.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                for (final c in [
                  accent.withValues(alpha: on ? 0.16 : 0),
                  ...palette.glassSheen,
                ])
                  Color.alphaBlend(c, fill),
              ],
            ),
            border: Border.all(
              color: on
                  ? accent.withValues(alpha: 0.55)
                  : _hover
                  ? accent.withValues(alpha: 0.35)
                  : palette.glassBorder,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: on ? 0.22 : 0),
                blurRadius: 16,
                // Only outside: the glass is see-through.
                blurStyle: BlurStyle.outer,
              ),
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: !lit
                      ? 0
                      : Theme.of(context).brightness == Brightness.dark
                      ? 0.25
                      : 0.08,
                ),
                blurRadius: 12,
                offset: const Offset(0, 4),
                blurStyle: BlurStyle.outer,
              ),
            ],
          ),
          // The slider's room is kept while it is folded away, so every
          // button is the same height and picking one never moves the rest.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                // The empty room picks it too.
                onTap: on ? null : widget.onTap,
                child: MouseRegion(
                  cursor: on
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.click,
                  child: SizedBox(
                    height: 34,
                    child: IgnorePointer(
                      ignoring: !on,
                      child: AnimatedOpacity(
                        opacity: on ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedSlide(
                          offset: on ? Offset.zero : const Offset(0, -0.3),
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutBack,
                          child: slider,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (widget.note.isEmpty) return tile;
    return Tooltip(
      message: widget.note,
      waitDuration: const Duration(milliseconds: 600),
      child: tile,
    );
  }
}
