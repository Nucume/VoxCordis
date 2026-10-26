import 'dart:convert';

import '../../data/schedule/schedule_repository.dart';
import 'untrusted_text.dart';

/// One reminder or automation from a Nemini export's `clock/tasks.json`.
class NeminiTask {
  const NeminiTask({
    required this.id,
    required this.kind,
    required this.text,
    required this.at,
    required this.repeat,
  });

  final String id;
  final ScheduleKind kind;
  final String text;
  final DateTime at;
  final Repeat repeat;
}

/// Reads Nemini's scheduled tasks. The file's exact layout isn't
/// documented, so this reads it loosely: a list of tasks (or one under
/// `tasks`/`items`, or a map of id → task), each with some text, a next
/// time and maybe a repeat or a cron line. Everything comes in paused, for
/// the human to check in the Plans tab before it runs.
class NeminiClock {
  static const _textKeys = [
    'prompt',
    'instruction',
    'instructions',
    'task',
    'text',
    'message',
    'title',
    'name',
    'description',
    'body',
  ];
  static const _timeKeys = [
    'next_run',
    'next_run_at',
    'nextRun',
    'nextRunAt',
    'next_at',
    'run_at',
    'runAt',
    'due',
    'due_at',
    'dueAt',
    'remind_at',
    'fire_at',
    'scheduled_for',
    'scheduledFor',
    'at',
    'when',
    'time',
    'start',
    'start_at',
  ];
  static const _repeatKeys = [
    'repeat',
    'recurrence',
    'rrule',
    'frequency',
    'interval',
    'schedule',
    'cron',
  ];

  /// The tasks in [source], the text of `clock/tasks.json`.
  static List<NeminiTask> parse(String? source, {DateTime? now}) {
    if (source == null) return const [];
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      return const [];
    }
    final List items = switch (json) {
      List l => l,
      Map m when m['tasks'] is List => m['tasks'] as List,
      Map m when m['items'] is List => m['items'] as List,
      Map m => [
        for (final e in m.entries)
          if (e.value is Map) {'id': e.key, ...e.value as Map},
      ],
      _ => const [],
    };
    final clock = now ?? DateTime.now();
    return [
      for (final (i, item) in items.indexed)
        if (item is Map)
          if (_task(item, i, clock) case final t?) t,
    ];
  }

  static String _s(Object? v) => v is String ? v : (v is num ? '$v' : '');

  static NeminiTask? _task(Map m, int index, DateTime now) {
    final rawText = _textKeys
        .map((k) => _s(m[k]))
        .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
    final text = UntrustedText.line(rawText, maxChars: 1000);
    if (text.isEmpty) return null;
    final id = _s(m['uuid']).isNotEmpty
        ? _s(m['uuid'])
        : _s(m['id']).isNotEmpty
        ? _s(m['id'])
        : 'task-$index';
    final type = '${m['type'] ?? m['kind'] ?? ''}'.toLowerCase();
    final kind = type.contains('remind')
        ? ScheduleKind.reminder
        : (type.isNotEmpty ||
              m['prompt'] != null ||
              m['instruction'] != null ||
              m['instructions'] != null)
        ? ScheduleKind.task
        : ScheduleKind.reminder;

    DateTime? at;
    for (final k in _timeKeys) {
      at = _time(m[k]);
      if (at != null) break;
    }
    Repeat repeat = Repeat.once;
    for (final k in _repeatKeys) {
      final v = m[k];
      if (v == null) continue;
      final cron = _cron('$v', now);
      if (cron != null) {
        repeat = cron.$1;
        at ??= cron.$2;
        break;
      }
      final r = v is Map
          ? Repeat.parse(v['every'] ?? v['frequency'] ?? v['unit'])
          : Repeat.parse(v);
      if (r != null) {
        repeat = r;
        break;
      }
    }
    // No time it could read: tomorrow morning, for the human to change.
    at ??= DateTime(now.year, now.month, now.day + 1, 9);
    return NeminiTask(
      id: id.length > 64 ? id.substring(0, 64) : id,
      kind: kind,
      text: text,
      at: at,
      repeat: repeat,
    );
  }

  /// An ISO time, or seconds or milliseconds since 1970.
  static DateTime? _time(Object? v) {
    if (v is num) {
      final ms = v > 1e11 ? v.toInt() : (v * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (v is! String || v.trim().isEmpty) return null;
    final t = DateTime.tryParse(v.trim());
    if (t == null) return null;
    return t.isUtc ? t.toLocal() : t;
  }

  /// A five-field cron line: `M H * * *` daily, `M H * * 1-5` weekdays,
  /// `M H * * D` weekly, `M H D * *` monthly, `0 */N * * *` every N hours.
  /// Returns the repeat and its next time.
  static (Repeat, DateTime)? _cron(String line, DateTime now) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length != 5) return null;
    final minute = int.tryParse(f[0]);
    final hour = int.tryParse(f[1]);
    final everyHours = RegExp(r'^\*/(\d+)$').firstMatch(f[1]);
    if (minute != null &&
        everyHours != null &&
        f[2] == '*' &&
        f[3] == '*' &&
        f[4] == '*') {
      final r = Repeat.hours(int.parse(everyHours[1]!));
      final anchor = DateTime(now.year, now.month, now.day, 0, minute);
      return (r, r.next(anchor, now));
    }
    if (minute == null || hour == null || f[3] != '*') return null;
    final anchor = DateTime(now.year, now.month, now.day, hour, minute);
    if (f[2] == '*' && f[4] == '*') {
      return (Repeat.daily, Repeat.daily.next(anchor, now));
    }
    if (f[2] == '*' && (f[4] == '1-5' || f[4].toUpperCase() == 'MON-FRI')) {
      return (Repeat.weekdays, Repeat.weekdays.next(anchor, now));
    }
    final day = int.tryParse(f[4]);
    if (f[2] == '*' && day != null && day >= 0 && day <= 7) {
      // Cron counts Sunday as 0 or 7, Dart as 7.
      final weekday = day == 0 ? 7 : day;
      var t = anchor;
      while (t.weekday != weekday) {
        t = DateTime(t.year, t.month, t.day + 1, hour, minute);
      }
      return (Repeat.weekly, Repeat.weekly.next(t, now));
    }
    final date = int.tryParse(f[2]);
    if (date != null && f[4] == '*') {
      final t = DateTime(now.year, now.month, date, hour, minute);
      return (Repeat.monthly, Repeat.monthly.next(t, now));
    }
    return null;
  }
}
