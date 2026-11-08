import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/images/picture_info.dart';
import 'draw_presets.dart';

/// What a picture was drawn with, over the picture viewer: every part on
/// its own, the prompt and everything to copy, and the prompt to keep as a
/// preset.
class PictureInfoPanel extends StatelessWidget {
  const PictureInfoPanel({super.key, required this.info, this.onClose});

  final PictureInfo info;
  final VoidCallback? onClose;

  void _copy(BuildContext context, String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('$what copied.')));
  }

  @override
  Widget build(BuildContext context) {
    const light = Colors.white;
    const muted = Color(0xB3FFFFFF);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'How it was drawn',
                        style: TextStyle(
                          color: light,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onClose != null)
                      IconButton(
                        tooltip: 'Close',
                        color: light,
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  children: [
                    for (final (label, value) in info.lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: muted,
                              ),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(
                              value,
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: light,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: light),
                      onPressed: () => _copy(context, info.prompt, 'Prompt'),
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy prompt'),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: light),
                      onPressed: () => _copy(context, info.text, 'Everything'),
                      icon: const Icon(Icons.copy_all_rounded, size: 16),
                      label: const Text('Copy all'),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: light),
                      onPressed: () async {
                        final saved = await askSaveDrawPreset(
                          context,
                          prompt: info.prompt,
                          negative: info.negative,
                        );
                        if (saved && context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Saved. Load it from the presets button '
                                'in Draw.',
                              ),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.star_outline_rounded, size: 16),
                      label: const Text('Save as preset'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
