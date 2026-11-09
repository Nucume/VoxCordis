import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Asks the human whether the companion may do something: what it is
/// ([what], usually [ApprovalBox]es), the companion's reason [why] above
/// it and a [note] on what allowing means below. [allow] are the ways to
/// say yes, the usual one last; closing the dialog is [deny].
Future<T> askApproval<T>(
  BuildContext context, {
  required IconData icon,
  required String title,
  String why = '',
  required List<Widget> what,
  required String note,
  bool warn = false,
  required T deny,
  required List<(String label, T answer)> allow,
}) async {
  final answer = await showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (why.isNotEmpty) ...[Text('“$why”'), const SizedBox(height: 12)],
            ...what,
            const SizedBox(height: 12),
            Text(
              note,
              style: TextStyle(
                fontSize: 12,
                color: warn ? Colors.orangeAccent : context.palette.textMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, deny),
          child: const Text('Don\'t allow'),
        ),
        for (final (i, (label, answer)) in allow.indexed)
          if (i < allow.length - 1)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, answer),
              child: Text(label),
            )
          else
            FilledButton(
              onPressed: () => Navigator.pop(context, answer),
              child: Text(label),
            ),
      ],
    ),
  );
  return answer ?? deny;
}

/// The dark box an approval shows the thing asked about in.
class ApprovalBox extends StatelessWidget {
  const ApprovalBox({super.key, required this.child, this.maxHeight});

  final Widget child;

  /// Past this height the box scrolls.
  final double? maxHeight;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(10),
    ),
    constraints: maxHeight == null
        ? null
        : BoxConstraints(maxHeight: maxHeight!),
    child: maxHeight == null ? child : SingleChildScrollView(child: child),
  );
}
