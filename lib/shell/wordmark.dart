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
        const Text.rich(
          TextSpan(
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
          style: TextStyle(fontSize: 13, letterSpacing: 2.2),
        ),
      ],
    );
  }
}
