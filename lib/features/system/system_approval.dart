import 'package:flutter/material.dart';

import '../../services/system/system_tools.dart';
import 'approval_dialog.dart';

/// Asks the human whether the companion may do [request]: once, always
/// (this exact command or target), or not at all. Closing the dialog is no.
Future<SystemApproval> askSystemApproval(
  BuildContext context,
  SystemRequest request, {
  required String companionName,
}) {
  final run = request.tool == SystemRequest.runTool;
  final warn =
      !run && (request.runnable || SystemTools.isRunnable(request.target));
  return askApproval(
    context,
    icon: run ? Icons.terminal_rounded : Icons.open_in_new_rounded,
    title: run
        ? '$companionName wants to run a command'
        : '$companionName wants to open something',
    why: request.why,
    what: [
      ApprovalBox(
        maxHeight: 220,
        child: SelectableText(
          request.target,
          style: const TextStyle(fontFamily: 'monospace', height: 1.4),
        ),
      ),
    ],
    note: run
        ? 'It runs as you, with your files and permissions, in '
              '${SystemTools.shellName}. Only allow what you '
              'understand.'
        : warn
        ? 'This opens a program or script: it will run as you. '
              'Only allow it if you trust it. This is asked every '
              'time.'
        : 'It opens with your usual app.',
    warn: run || warn,
    deny: SystemApproval.deny,
    allow: [
      // A program or script is asked about every time.
      if (!warn) ('Always allow this', SystemApproval.always),
      ('Allow once', SystemApproval.once),
    ],
  );
}
