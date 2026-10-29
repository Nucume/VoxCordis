import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// A text field that grows with its text, and can be dragged taller or
/// shorter by the little grip in its bottom right corner. Double-clicking
/// the grip goes back to growing with the text.
class ResizableField extends StatefulWidget {
  const ResizableField({
    super.key,
    required this.controller,
    this.hintText,
    this.minLines = 1,
    this.maxLines = 4,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? hintText;

  /// The lines the field shows before it has been dragged, and the most it
  /// grows to by itself.
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  State<ResizableField> createState() => _ResizableFieldState();
}

class _ResizableFieldState extends State<ResizableField> {
  static const _minHeight = 56.0;
  static const _maxHeight = 640.0;

  /// The height the human dragged it to, or null while it fits its text.
  double? _height;

  bool _dragging = false;

  void _drag(PointerMoveEvent e) {
    if (!_dragging) return;
    final shown = _height ?? (context.size?.height ?? _minHeight);
    setState(
      () => _height = (shown + e.delta.dy).clamp(_minHeight, _maxHeight),
    );
  }

  @override
  Widget build(BuildContext context) {
    final decoration = InputDecoration(hintText: widget.hintText);
    final height = _height;
    return Stack(
      children: [
        if (height == null)
          TextField(
            controller: widget.controller,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            onChanged: widget.onChanged,
            decoration: decoration,
          )
        else
          SizedBox(
            height: height,
            child: TextField(
              controller: widget.controller,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              onChanged: widget.onChanged,
              decoration: decoration,
            ),
          ),
        Positioned(
          right: 2,
          bottom: 2,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            // Raw pointer events rather than a pan gesture, so the grip
            // follows the pointer from the first pixel.
            child: Listener(
              key: const ValueKey('resize-grip'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _dragging = true,
              onPointerMove: _drag,
              onPointerUp: (_) => _dragging = false,
              onPointerCancel: (_) => _dragging = false,
              child: GestureDetector(
                onDoubleTap: () => setState(() => _height = null),
                child: Tooltip(
                  message: 'Drag to resize',
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CustomPaint(
                      painter: _GripPainter(context.palette.textMuted),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GripPainter extends CustomPainter {
  _GripPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final inset in const [5.0, 10.0]) {
      canvas.drawLine(
        Offset(size.width - 4, size.height - inset - 2),
        Offset(size.width - inset - 2, size.height - 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}
