import 'package:flutter/material.dart';

import '../../services/calendar/calendar_event.dart';
import '../../services/calendar/calendar_tools.dart';
import '../../theme/app_theme.dart';
import 'approval_dialog.dart';

/// Asks the human whether the companion may add, change or delete a
/// calendar event, showing the event (and for a change, what it was).
/// Closing the dialog is no.
Future<bool> askCalendarApproval(
  BuildContext context,
  CalendarChange change, {
  required String companionName,
}) {
  final e = change.event;
  final (title, icon, allow) = switch (change.kind) {
    CalendarChangeKind.add => (
      '$companionName wants to add an event',
      Icons.event_available_rounded,
      'Add it',
    ),
    CalendarChangeKind.change => (
      '$companionName wants to change an event',
      Icons.edit_calendar_rounded,
      'Change it',
    ),
    CalendarChangeKind.delete => (
      '$companionName wants to delete an event',
      Icons.event_busy_rounded,
      'Delete it',
    ),
  };
  return askApproval(
    context,
    icon: icon,
    title: title,
    what: [
      if (change.before case final before?) ...[
        _EventBox(event: before, faded: true),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Center(child: Icon(Icons.arrow_downward_rounded)),
        ),
      ],
      _EventBox(event: e, struck: change.kind == CalendarChangeKind.delete),
    ],
    note: [
      if (change.calendar.isNotEmpty) 'Calendar: ${change.calendar}.',
      if (e.repeats && change.kind == CalendarChangeKind.delete)
        'This repeats; only this time goes.',
      if (e.repeats && change.kind == CalendarChangeKind.change)
        'This repeats; only this time changes.',
      'You can stop being asked in Settings → Connections.',
    ].join(' '),
    deny: false,
    allow: [(allow, true)],
  );
}

class _EventBox extends StatelessWidget {
  const _EventBox({
    required this.event,
    this.faded = false,
    this.struck = false,
  });

  final CalendarEvent event;
  final bool faded;
  final bool struck;

  @override
  Widget build(BuildContext context) {
    final muted = context.palette.textMuted;
    final strike = struck ? TextDecoration.lineThrough : null;
    return Opacity(
      opacity: faded ? 0.6 : 1,
      child: ApprovalBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.title,
              style: TextStyle(fontWeight: FontWeight.w600, decoration: strike),
            ),
            const SizedBox(height: 4),
            Text(event.when, style: TextStyle(decoration: strike)),
            if (event.location.isNotEmpty)
              Text(event.location, style: TextStyle(color: muted)),
            if (event.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  event.notes,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
