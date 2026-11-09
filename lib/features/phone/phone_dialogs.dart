import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../theme/app_theme.dart';

/// Asks on the computer whether the phone that just scanned the QR code
/// (or, with [check], tapped Pair with my PC) may use VoxCordis, and what to
/// call it. Null is no.
///
/// Only someone at the computer can say yes, so a code seen over a
/// shoulder isn't enough on its own. With [check], both screens show it,
/// and they only match when nobody is in between.
Future<String?> askAllowPhone(
  AppServices services, {
  required String name,
  required String address,
  String? check,
}) async {
  await services.background?.showWindow();
  final context = services.navigatorKey.currentContext;
  if (context == null || !context.mounted) return null;
  final field = TextEditingController(text: name);
  try {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final palette = context.palette;
        void yes() => Navigator.pop(
          context,
          field.text.trim().isEmpty ? name : field.text.trim(),
        );
        return AlertDialog(
          icon: Icon(
            Icons.smartphone_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: const Text('Let this phone use VoxCordis?'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (check != null) ...[
                  Text(
                    'Does your phone show this code?',
                    style: TextStyle(color: palette.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(22, 10, 14, 10),
                      decoration: BoxDecoration(
                        color: palette.textMuted.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: palette.textMuted.withValues(alpha: 0.25),
                        ),
                      ),
                      child: SelectionContainer.disabled(
                        child: Text(
                          check,
                          semanticsLabel: check.split('').join(' '),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 8,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Only allow it if the code is the same on both screens.',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  'A phone at $address just ${check != null ? 'asked to pair' : 'scanned your code'}. Once '
                  'allowed, it can chat with '
                  '${services.settings.value.companionName}, see and draw '
                  'pictures and play Voces Mundi, until you remove it.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: field,
                  autofocus: true,
                  maxLength: 40,
                  decoration: const InputDecoration(labelText: 'Call it'),
                  onSubmitted: (_) => yes(),
                ),
                Text(
                  check != null
                      ? 'If you didn\'t just tap Pair on your phone, '
                            'don\'t allow this request.'
                      : 'If you didn\'t just scan the code yourself, '
                            'don\'t allow this request.',
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Don\'t allow'),
            ),
            FilledButton(onPressed: yes, child: const Text('Allow')),
          ],
        );
      },
    );
  } finally {
    field.dispose();
  }
}
