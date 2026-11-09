import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The heart mark and "VOX CORDIS", at the foot of the companion card.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(AppTheme.heartMark, height: 20),
        const SizedBox(width: 8),
        const WordmarkText(),
      ],
    );
  }
}

/// "VOX CORDIS" the way the mark writes it: the first word heavy, the
/// second light.
class WordmarkText extends StatelessWidget {
  const WordmarkText({super.key, this.size = 13, this.spacing = 2.2});

  final double size;
  final double spacing;

  @override
  Widget build(BuildContext context) => Text.rich(
    const TextSpan(
      children: [
        TextSpan(
          text: 'VOX ',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        TextSpan(
          text: 'CORDIS',
          style: TextStyle(fontWeight: FontWeight.w300),
        ),
      ],
    ),
    style: TextStyle(fontSize: size, letterSpacing: spacing),
  );
}
