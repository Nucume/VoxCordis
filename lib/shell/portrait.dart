import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The companion's picture as a rounded square with a glowing accent rim.
/// Without a picture it shows [placeholder], or the VoxCordis heart.
class Portrait extends StatelessWidget {
  const Portrait({super.key, this.path, this.size, this.placeholder});

  final String? path;

  /// Edge length; null fills the available width.
  final double? size;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final file = path == null ? null : File(path!);
    final hasImage = file != null && file.existsSync();

    return LayoutBuilder(
      builder: (context, constraints) {
        final edge = size ?? constraints.maxWidth;
        final radius = edge * 0.18;
        return Container(
          width: edge,
          height: edge,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 3),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent,
                const Color(0xFFFF7AB6),
                const Color(0xFF4F7CFF),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.25),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: const Color(0xFF0D1426),
              child: hasImage
                  // Keyed by the file's time, so a new picture saved under
                  // the same name (avatar.png) is loaded afresh.
                  ? Image.file(
                      file,
                      key: ValueKey(
                        '${file.path}@${file.lastModifiedSync().microsecondsSinceEpoch}',
                      ),
                      fit: BoxFit.cover,
                    )
                  : Center(
                      child:
                          placeholder ??
                          Padding(
                            padding: EdgeInsets.all(edge * 0.18),
                            child: Image.asset(AppTheme.heartMark),
                          ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
