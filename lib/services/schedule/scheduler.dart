import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/schedule/schedule_repository.dart';

/// How a scheduled turn went, for the run log and the notification.
class ScheduledOutcome {
  const ScheduledOutcome({required this.ok, required this.text});

  final bool ok;

  /// The companion's message, or why it failed.
  final String text;
}

/// Makes reminders and tasks happen while VoxCordis runs: every half
/// minute it looks for what is due, has the companion write it in the
/// chat ([run]), notifies the human when the window isn't in front, and
/// moves each one on to its next time.
///
/// What came due while VoxCordis was closed happens once, at the next
/// start, however many times it would have repeated meanwhile. Tasks stop
/// for the day after [AppSettings.automationRunsPerDay] runs.
class Scheduler {
  Scheduler({
    required this.repo,
    required this.run,
    required this.runsPerDay,
    required this.notify,
    required this.focused,
    this.onChanged,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The current companion's schedules; changes when they switch.
  final ScheduleRepository Function() repo;

  /// Has the companion write the reminder or do the task. Null when it
  /// can't right now (a reply is being written): tried again next time.
  final Future<ScheduledOutcome?> Function(Schedule s, {required bool late})
  run;
  final int Function() runsPerDay;
  final Future<void> Function(String title, String body) notify;
  final Future<bool> Function() focused;
  final VoidCallback? onChanged;
  final DateTime Function() _clock;

  static const every = Duration(seconds: 30);

  /// Due longer ago than this counts as missed while VoxCordis was closed.
  static const lateAfter = Duration(minutes: 10);

  Timer? _timer;
  bool _ticking = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => tick());
    Timer(const Duration(seconds: 8), tick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs whatever is due now. Public for tests.
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final r = repo();
      final now = _clock();
      for (final s in await r.due(now)) {
        if (s.kind == ScheduleKind.task &&
            await r.runsToday(now) >= runsPerDay()) {
          await r.logRun(
            s.id,
            now,
            false,
            'Skipped: today\'s limit of ${runsPerDay()} runs was reached.',
          );
          await r.advance(s, now);
          onChanged?.call();
          continue;
        }
        final late = now.difference(s.nextAt) > lateAfter;
        final outcome = await run(s, late: late);
        if (outcome == null) break; // busy: next tick
        // The human may have switched companion while this ran, and the
        // old database is closed then: it goes again on that one's turn.
        if (!identical(r, repo())) break;
        await r.logRun(s.id, now, outcome.ok, outcome.text);
        await r.advance(s, _clock());
        onChanged?.call();
        if (!await focused()) {
          await notify(
            s.kind == ScheduleKind.reminder
                ? 'Reminder'
                : 'Done: ${_short(s.text)}',
            outcome.text,
          );
        }
      }
    } catch (e) {
      debugPrint('Scheduler: $e');
    } finally {
      _ticking = false;
    }
  }

  static String _short(String s) =>
      s.length > 50 ? '${s.substring(0, 49)}…' : s;
}
