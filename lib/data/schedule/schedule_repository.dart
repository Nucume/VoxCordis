import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// A reminder tells the human something at a time; a task is a job the
/// companion does itself at a time (look something up, sum up the week)
/// and then tells the human about.
enum ScheduleKind { reminder, task }

/// How a schedule repeats. Stored as text: `''` (once), `daily`,
/// `weekdays`, `weekly`, `monthly`, or `hours:N` / `minutes:N`.
class Repeat {
  const Repeat._(this.code);

  final String code;

  static const once = Repeat._('');
  static const daily = Repeat._('daily');
  static const weekdays = Repeat._('weekdays');
  static const weekly = Repeat._('weekly');
  static const monthly = Repeat._('monthly');

  /// Every [n] hours.
  factory Repeat.hours(int n) => Repeat._('hours:${n.clamp(1, 24 * 7)}');

  /// Every [n] minutes, at least 15 so it can't run constantly.
  factory Repeat.minutes(int n) => Repeat._('minutes:${n.clamp(15, 24 * 60)}');

  bool get isOnce => code.isEmpty;

  /// Reads what a model or a file wrote: the codes above, or everyday
  /// words like "every day", "every 2 hours", "weekdays". Null for words
  /// it doesn't know.
  static Repeat? parse(Object? raw) {
    final t = '${raw ?? ''}'.trim().toLowerCase();
    if (t.isEmpty || t == 'none' || t == 'once' || t == 'no' || t == 'never') {
      return once;
    }
    if (const {'daily', 'every day', 'each day', 'day'}.contains(t)) {
      return daily;
    }
    if (t.contains('weekday') || t == 'every workday' || t == 'workdays') {
      return weekdays;
    }
    if (const {'weekly', 'every week', 'each week', 'week'}.contains(t)) {
      return weekly;
    }
    if (const {'monthly', 'every month', 'each month', 'month'}.contains(t)) {
      return monthly;
    }
    if (const {'hourly', 'every hour', 'each hour', 'hour'}.contains(t)) {
      return Repeat.hours(1);
    }
    final code = RegExp(r'^(hours|minutes):(\d+)$').firstMatch(t);
    if (code != null) {
      final n = int.parse(code[2]!);
      return code[1] == 'hours' ? Repeat.hours(n) : Repeat.minutes(n);
    }
    final words = RegExp(
      r'^(?:every\s+)?(\d+)\s*(h|hrs?|hours?|m|mins?|minutes?)$',
    ).firstMatch(t);
    if (words != null) {
      final n = int.parse(words[1]!);
      return words[2]!.startsWith('m') ? Repeat.minutes(n) : Repeat.hours(n);
    }
    return null;
  }

  /// The next time after [after], at the time of day [anchor] has.
  DateTime next(DateTime anchor, DateTime after) {
    final parts = code.split(':');
    switch (parts.first) {
      case 'hours' || 'minutes':
        final step = parts.first == 'hours'
            ? Duration(hours: int.parse(parts[1]))
            : Duration(minutes: int.parse(parts[1]));
        var t = anchor;
        if (!t.isAfter(after)) {
          final behind = after.difference(t).inMicroseconds;
          t = t.add(step * (behind ~/ step.inMicroseconds + 1));
        }
        return t;
      case 'daily' || 'weekdays':
        var t = _sameTimeOn(anchor, after);
        while (!t.isAfter(after) ||
            (code == 'weekdays' && t.weekday > DateTime.friday)) {
          t = _sameTimeOn(anchor, t.add(const Duration(days: 1)));
        }
        return t;
      case 'weekly':
        var t = _sameTimeOn(anchor, after);
        while (t.weekday != anchor.weekday || !t.isAfter(after)) {
          t = _sameTimeOn(anchor, t.add(const Duration(days: 1)));
        }
        return t;
      case 'monthly':
        var month = DateTime(after.year, after.month);
        while (true) {
          final last = DateTime(month.year, month.month + 1, 0).day;
          final t = DateTime(
            month.year,
            month.month,
            anchor.day > last ? last : anchor.day,
            anchor.hour,
            anchor.minute,
          );
          if (t.isAfter(after)) return t;
          month = DateTime(month.year, month.month + 1);
        }
      default:
        return anchor;
    }
  }

  /// [day]'s date at [anchor]'s local time of day; built from the date
  /// parts, so it stays right across daylight saving changes.
  static DateTime _sameTimeOn(DateTime anchor, DateTime day) =>
      DateTime(day.year, day.month, day.day, anchor.hour, anchor.minute);

  /// In words, for the list and for the companion.
  String get label {
    final parts = code.split(':');
    return switch (parts.first) {
      '' => 'once',
      'daily' => 'every day',
      'weekdays' => 'every weekday',
      'weekly' => 'every week',
      'monthly' => 'every month',
      'hours' => parts[1] == '1' ? 'every hour' : 'every ${parts[1]} hours',
      'minutes' => 'every ${parts[1]} minutes',
      _ => code,
    };
  }

  @override
  bool operator ==(Object other) => other is Repeat && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

class Schedule {
  const Schedule({
    required this.id,
    required this.kind,
    required this.text,
    required this.nextAt,
    this.repeat = Repeat.once,
    this.active = true,
    required this.createdAt,
    this.lastRunAt,
    this.origin = 'chat',
  });

  final String id;
  final ScheduleKind kind;

  /// What to remind of, or the task to do, in the companion's words.
  final String text;

  /// When it is due next, local time.
  final DateTime nextAt;
  final Repeat repeat;

  /// Paused or done when false: a one-off that already happened, or an
  /// imported task waiting for the human to look at it.
  final bool active;
  final DateTime createdAt;
  final DateTime? lastRunAt;

  /// `chat` (the companion set it), `human` (added in the Reminders tab)
  /// or `nemini` (imported).
  final String origin;

  /// A short id the companion can say back: the first 8 characters.
  String get shortId => id.substring(0, 8);

  factory Schedule.fromRow(Map<String, Object?> r) => Schedule(
    id: r['id'] as String,
    kind: ScheduleKind.values.asNameMap()[r['kind']] ?? ScheduleKind.reminder,
    text: r['text'] as String,
    nextAt: DateTime.parse(r['next_at'] as String).toLocal(),
    repeat: Repeat.parse(r['repeat']) ?? Repeat.once,
    active: r['active'] == 1,
    createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
    lastRunAt: r['last_run_at'] == null
        ? null
        : DateTime.parse(r['last_run_at'] as String).toLocal(),
    origin: r['origin'] as String? ?? 'chat',
  );

  Map<String, Object?> toJson() => {
    'id': shortId,
    'kind': kind.name,
    'text': text,
    'when': stamp(nextAt),
    'repeat': repeat.label,
    if (!active) 'paused': true,
  };

  /// `2026-11-02 18:30`, the way times are written to the companion.
  static String stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

/// One automation run, for the log in the Reminders tab.
class ScheduleRun {
  const ScheduleRun({
    required this.scheduleId,
    required this.startedAt,
    required this.ok,
    required this.summary,
  });

  final String scheduleId;
  final DateTime startedAt;
  final bool ok;
  final String summary;
}

/// The companion's reminders and tasks, in its own database.
class ScheduleRepository {
  ScheduleRepository(this._db);

  final Database _db;
  static const _uuid = Uuid();

  static String _utc(DateTime t) => t.toUtc().toIso8601String();

  Future<Schedule> add({
    required ScheduleKind kind,
    required String text,
    required DateTime at,
    Repeat repeat = Repeat.once,
    String origin = 'chat',
    bool active = true,
    DateTime? now,
  }) async {
    final s = Schedule(
      id: _uuid.v4(),
      kind: kind,
      text: text.trim(),
      nextAt: at,
      repeat: repeat,
      active: active,
      createdAt: now ?? DateTime.now(),
      origin: origin,
    );
    await _db.insert('schedules', {
      'id': s.id,
      'kind': kind.name,
      'text': s.text,
      'next_at': _utc(at),
      'repeat': repeat.code,
      'active': active ? 1 : 0,
      'created_at': _utc(s.createdAt),
      'origin': origin,
    });
    return s;
  }

  /// Everything, soonest first; paused and finished ones last.
  Future<List<Schedule>> all() async => [
    for (final r in await _db.query(
      'schedules',
      orderBy: 'active DESC, next_at ASC',
    ))
      Schedule.fromRow(r),
  ];

  /// The ones still to come.
  Future<List<Schedule>> upcoming() async => [
    for (final r in await _db.query(
      'schedules',
      where: 'active = 1',
      orderBy: 'next_at ASC',
    ))
      Schedule.fromRow(r),
  ];

  /// Active schedules due at [now] or before.
  Future<List<Schedule>> due(DateTime now) async => [
    for (final r in await _db.query(
      'schedules',
      where: 'active = 1 AND next_at <= ?',
      whereArgs: [_utc(now)],
      orderBy: 'next_at ASC',
    ))
      Schedule.fromRow(r),
  ];

  /// Finds one by its id or the short id the companion was shown.
  Future<Schedule?> find(String id) async {
    final key = id.trim().toLowerCase();
    if (key.length < 4) return null;
    final rows = await _db.query(
      'schedules',
      where: 'id = ? OR id LIKE ?',
      whereArgs: [key, '$key%'],
    );
    return rows.length == 1 ? Schedule.fromRow(rows.single) : null;
  }

  /// After [s] went off at [now]: on to its next time, or done.
  Future<void> advance(Schedule s, DateTime now) => _db.update(
    'schedules',
    {
      'last_run_at': _utc(now),
      if (s.repeat.isOnce)
        'active': 0
      else
        'next_at': _utc(s.repeat.next(s.nextAt, now)),
    },
    where: 'id = ?',
    whereArgs: [s.id],
  );

  Future<void> update(
    String id, {
    ScheduleKind? kind,
    String? text,
    DateTime? at,
    Repeat? repeat,
    bool? active,
  }) => _db.update(
    'schedules',
    {
      'kind': ?kind?.name,
      'text': ?text,
      if (at != null) 'next_at': _utc(at),
      if (repeat != null) 'repeat': repeat.code,
      if (active != null) 'active': active ? 1 : 0,
    },
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> delete(String id) async {
    await _db.delete('schedules', where: 'id = ?', whereArgs: [id]);
    await _db.delete(
      'schedule_runs',
      where: 'schedule_id = ?',
      whereArgs: [id],
    );
  }

  Future<void> logRun(
    String scheduleId,
    DateTime at,
    bool ok,
    String summary,
  ) => _db.insert('schedule_runs', {
    'id': _uuid.v4(),
    'schedule_id': scheduleId,
    'started_at': _utc(at),
    'ok': ok ? 1 : 0,
    'summary': summary.length > 400 ? summary.substring(0, 400) : summary,
  });

  /// Automation runs since local midnight of [now], for the daily cap.
  Future<int> runsToday(DateTime now) async {
    final midnight = DateTime(now.year, now.month, now.day);
    final rows = await _db.rawQuery(
      'SELECT count(*) AS n FROM schedule_runs WHERE started_at >= ?',
      [_utc(midnight)],
    );
    return rows.single['n'] as int;
  }

  /// The latest runs, newest first.
  Future<List<ScheduleRun>> runs({int limit = 30}) async => [
    for (final r in await _db.query(
      'schedule_runs',
      orderBy: 'started_at DESC',
      limit: limit,
    ))
      ScheduleRun(
        scheduleId: r['schedule_id'] as String,
        startedAt: DateTime.parse(r['started_at'] as String).toLocal(),
        ok: r['ok'] == 1,
        summary: r['summary'] as String,
      ),
  ];
}
