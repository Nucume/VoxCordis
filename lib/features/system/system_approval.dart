import 'package:flutter/material.dart';

import '../../services/system/system_tools.dart';
import '../../theme/app_theme.dart';

/// Asks the human whether the companion may do [request]: once, always
/// (this exact command or target), or not at all. Closing the dialog is no.
Future<SystemApproval> askSystemApproval(
  BuildContext context,
  SystemRequest request, {
  required String companionName,
}) async {
  final run = request.tool == SystemRequest.runTool;
  final warn =
      !run && (request.runnable || SystemTools.isRunnable(request.target));
  final answer = await showDialog<SystemApproval>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Icon(
        run ? Icons.terminal_rounded : Icons.open_in_new_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(
        run
            ? '$companionName wants to run a command'
            : '$companionName wants to open something',
      ),
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
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  request.target,
                  style: const TextStyle(fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              run
                  ? 'It runs as you, with your files and permissions, in '
                        '${SystemTools.shellName}. Only allow what you '
                        'understand.'
                  : warn
                  ? 'This opens a program or script: it will run as you. '
                        'Only allow it if you trust it. This is asked every '
                        'time.'
                  : 'It opens with your usual app.',
              style: TextStyle(
                fontSize: 12,
                color: run || warn
                    ? Colors.orangeAccent
                    : context.palette.textMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, SystemApproval.deny),
          child: const Text('Don\'t allow'),
        ),
        // A program or script is asked about every time.
        if (!warn)
          OutlinedButton(
            onPressed: () => Navigator.pop(context, SystemApproval.always),
            child: const Text('Always allow this'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, SystemApproval.once),
          child: const Text('Allow once'),
        ),
      ],
    ),
  );
  return answer ?? SystemApproval.deny;
}
