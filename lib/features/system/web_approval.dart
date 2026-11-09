import 'package:flutter/material.dart';

import '../../services/web/web_tools.dart';
import 'approval_dialog.dart';

/// Asks the human whether the companion may do [request] on a site in its
/// browser: send a form, or type into a field that isn't a search box.
/// Closing the dialog is no.
Future<bool> askWebApproval(
  BuildContext context,
  WebRequest request, {
  required String companionName,
}) => askApproval(
  context,
  icon: Icons.travel_explore_rounded,
  title: '$companionName wants to do something on ${request.site}',
  why: request.why,
  what: [
    ApprovalBox(
      child: SelectableText(
        '${request.action[0].toUpperCase()}${request.action.substring(1)}',
        style: const TextStyle(height: 1.4),
      ),
    ),
  ],
  note:
      'This happens in $companionName\'s own browser, which has none '
      'of your logins. Sending a form can still post, sign up or '
      'order something, so only allow what you want done.',
  deny: false,
  allow: const [('Allow', true)],
);
