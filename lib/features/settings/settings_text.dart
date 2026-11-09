import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The heading over a group of settings.
class SettingsSection extends StatelessWidget {
  const SettingsSection(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 2),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// Small print under a setting: what it does, or in [color] what went
/// wrong.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: color ?? context.palette.textMuted),
    ),
  );
}
