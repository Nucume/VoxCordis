import 'package:flutter/material.dart';

import '../../services/web/web_tools.dart';
import '../../theme/app_theme.dart';

/// Asks the human whether the companion may do [request] on a site in its
/// browser: send a form, or type into a field that isn't a search box.
/// Closing the dialog is no.
Future<bool> askWebApproval(
  BuildContext context,
  WebRequest request, {
  required String companionName,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Icon(
        Icons.travel_explore_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text('$companionName wants to do something on ${request.site}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (request.why.isNotEmpty) ...[
              Text('“${request.why}”'),
              const SizedBox(height: 12),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                '${request.action[0].toUpperCase()}${request.action.substring(1)}',
                style: const TextStyle(height: 1.4),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'This happens in $companionName\'s own browser, which has none '
              'of your logins. Sending a form can still post, sign up or '
              'order something, so only allow what you want done.',
              style: TextStyle(fontSize: 12, color: context.palette.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Don\'t allow'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  return answer ?? false;
}
