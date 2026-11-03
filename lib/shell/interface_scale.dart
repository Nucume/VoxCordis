import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Draws the app [scale] times bigger or smaller than the computer's own
/// scaling says, text and all. It never goes bigger than the window has
/// room for, and shrinks to fit when the window is under the size the
/// layout was made for, so a small or heavily scaled screen still shows
/// everything.
class InterfaceScale extends StatelessWidget {
  const InterfaceScale({super.key, required this.scale, required this.child});

  /// The size the layout needs at 100%.
  static const designSize = Size(820, 720);

  final double scale;
  final Widget child;

  /// What really applies in a window of [window].
  static double effective(Size window, double wanted) => math.min(
    wanted,
    math.min(
      window.width / designSize.width,
      window.height / designSize.height,
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (!box.hasBoundedWidth || !box.hasBoundedHeight) return child;
      final s = effective(box.biggest, scale);
      if ((s - 1).abs() < 0.001 || s <= 0) return child;
      final inner = Size(box.maxWidth / s, box.maxHeight / s);
      return FittedBox(
        fit: BoxFit.fill,
        child: SizedBox.fromSize(
          size: inner,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(size: inner),
            child: child,
          ),
        ),
      );
    },
  );
}
