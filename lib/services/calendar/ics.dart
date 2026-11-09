import 'calendar_event.dart';

/// One property line of an iCalendar file: `DTSTART;TZID=Europe/Zurich:…`.
class IcsLine {
  IcsLine(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;

  static IcsLine? parse(String line) {
    // The value starts at the first colon outside a quoted parameter.
    var quoted = false;
    var colon = -1;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') quoted = !quoted;
      if (ch == ':' && !quoted) {
        colon = i;
        break;
      }
    }
    if (colon <= 0) return null;
    final head = line.substring(0, colon).split(';');
    final params = <String, String>{};
    for (final p in head.skip(1)) {
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      params[p.substring(0, eq).toUpperCase()] = p
          .substring(eq + 1)
          .replaceAll('"', '');
    }
    return IcsLine(head.first.toUpperCase(), params, line.substring(colon + 1));
  }
}

/// A VEVENT as written in the file, before repeats are worked out.
class IcsEvent {
  IcsEvent(this.lines);

  final List<IcsLine> lines;

  IcsLine? first(String name) => lines.where((l) => l.name == name).firstOrNull;

  String text(String name) => Ics.unescape(first(name)?.value ?? '');

  String get uid => first('UID')?.value ?? '';
  bool get cancelled => first('STATUS')?.value.toUpperCase() == 'CANCELLED';

  ({DateTime at, bool day})? get start => Ics.readTime(first('DTSTART'));

  /// When this one replaces a single time of a repeating event.
  ({DateTime at, bool day})? get recurrenceId =>
      Ics.readTime(first('RECURRENCE-ID'));

  /// The end, from DTEND or DURATION; a day after a day's start, else the
  /// start itself.
  DateTime endFor(DateTime start, bool day) {
    final end = Ics.readTime(first('DTEND'));
    if (end != null) return end.at;
    final duration = Ics.readDuration(first('DURATION')?.value ?? '');
    if (duration != null) return start.add(duration);
    return day ? DateTime(start.year, start.month, start.day + 1) : start;
  }

  List<DateTime> get exdates => [
    for (final l in lines.where((l) => l.name == 'EXDATE'))
      for (final v in l.value.split(','))
        if (Ics.readTime(IcsLine('EXDATE', l.params, v)) case final t?) t.at,
  ];
}

/// Reads and writes the parts of iCalendar (RFC 5545) a calendar chat
/// needs: events, their times and simple repeats.
///
/// Times with a TZID are read as the computer's own time: nearly always
/// right, since people's calendars are in the zone they live in. UTC times
/// (ending in Z) are turned into local time.
abstract final class Ics {
  /// Joins folded lines (a line starting with a space continues the last).
  static List<String> unfold(String text) {
    final out = <String>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      if ((raw.startsWith(' ') || raw.startsWith('\t')) && out.isNotEmpty) {
        out[out.length - 1] += raw.substring(1);
      } else if (raw.isNotEmpty) {
        out.add(raw);
      }
    }
    return out;
  }

  /// Every VEVENT in [text] (alarms inside them left out).
  static List<IcsEvent> parse(String text) {
    final events = <IcsEvent>[];
    List<IcsLine>? current;
    var depth = 0;
    for (final line in unfold(text)) {
      final l = IcsLine.parse(line);
      if (l == null) continue;
      if (l.name == 'BEGIN') {
        if (l.value.toUpperCase() == 'VEVENT' && current == null) {
          current = [];
          depth = 0;
        } else if (current != null) {
          depth++;
        }
        continue;
      }
      if (l.name == 'END') {
        if (current != null &&
            depth == 0 &&
            l.value.toUpperCase() == 'VEVENT') {
          events.add(IcsEvent(current));
          current = null;
        } else if (current != null) {
          depth--;
        }
        continue;
      }
      if (current != null && depth == 0) current.add(l);
    }
    return events;
  }

  static String unescape(String v) => v.replaceAllMapped(
    RegExp(r'\\([nN,;\\])'),
    (m) => switch (m[1]) {
      'n' || 'N' => '\n',
      final c => c!,
    },
  );

  static String escape(String v) => v
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll(RegExp(r'\r?\n'), '\\n');

  /// `20261109`, `20261109T140000`, `20261109T130000Z`.
  static ({DateTime at, bool day})? readTime(IcsLine? line) {
    if (line == null) return null;
    final v = line.value.trim();
    final m = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$',
    ).firstMatch(v);
    if (m == null) return null;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    if (m[4] == null) return (at: DateTime(y, mo, d), day: true);
    final h = int.parse(m[4]!), mi = int.parse(m[5]!);
    final s = int.tryParse(m[6] ?? '') ?? 0;
    final at = m[7] != null
        ? DateTime.utc(y, mo, d, h, mi, s).toLocal()
        : DateTime(y, mo, d, h, mi, s);
    return (at: at, day: false);
  }

  /// `PT1H30M`, `P1D`, `P2W`.
  static Duration? readDuration(String v) {
    final m = RegExp(
      r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
    ).firstMatch(v.trim());
    if (m == null) return null;
    int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
    final d = Duration(
      days: n(2) * 7 + n(3),
      hours: n(4),
      minutes: n(5),
      seconds: n(6),
    );
    return m[1] == '-' ? -d : d;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String dateValue(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}';

  static String utcValue(DateTime t) {
    final u = t.toUtc();
    return '${dateValue(u)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
  }

  /// The event's times as property lines.
  static List<String> timeLines(CalendarEvent e) => e.allDay
      ? [
          'DTSTART;VALUE=DATE:${dateValue(e.start)}',
          'DTEND;VALUE=DATE:${dateValue(e.end)}',
        ]
      : ['DTSTART:${utcValue(e.start)}', 'DTEND:${utcValue(e.end)}'];

  /// Splits lines longer than 75 characters, as the format asks.
  static String fold(String line) {
    if (line.length <= 75) return line;
    final parts = <String>[line.substring(0, 75)];
    for (var i = 75; i < line.length; i += 74) {
      parts.add(
        ' ${line.substring(i, i + 74 > line.length ? line.length : i + 74)}',
      );
    }
    return parts.join('\r\n');
  }

  /// A whole calendar file holding [e] alone, for a new event.
  static String write(CalendarEvent e, {required String uid, DateTime? now}) {
    final lines = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Nucume//VoxCordis//EN',
      'BEGIN:VEVENT',
      'UID:$uid',
      'DTSTAMP:${utcValue(now ?? DateTime.now())}',
      ...timeLines(e),
      'SUMMARY:${escape(e.title)}',
      if (e.location.isNotEmpty) 'LOCATION:${escape(e.location)}',
      if (e.notes.isNotEmpty) 'DESCRIPTION:${escape(e.notes)}',
      'END:VEVENT',
      'END:VCALENDAR',
    ];
    return '${lines.map(fold).join('\r\n')}\r\n';
  }

  /// [ics] with the event's title, times, place and notes replaced by
  /// [e]'s; everything else (alarms, guests, repeats) is kept as it was.
  static String patch(String ics, CalendarEvent e, {DateTime? now}) {
    final out = <String>[];
    var inEvent = false;
    var depth = 0;
    var done = false;
    const replaced = {
      'DTSTART',
      'DTEND',
      'DURATION',
      'SUMMARY',
      'LOCATION',
      'DESCRIPTION',
      'DTSTAMP',
      'LAST-MODIFIED',
      'SEQUENCE',
    };
    var sequence = 0;
    for (final line in unfold(ics)) {
      final l = IcsLine.parse(line);
      if (l?.name == 'BEGIN' && l!.value.toUpperCase() == 'VEVENT' && !done) {
        inEvent = true;
        depth = 0;
        out.add(line);
        continue;
      }
      if (inEvent && l?.name == 'BEGIN') depth++;
      if (inEvent && l?.name == 'END') {
        if (depth > 0) {
          depth--;
        } else {
          final stamp = utcValue(now ?? DateTime.now());
          out.addAll([
            'DTSTAMP:$stamp',
            'LAST-MODIFIED:$stamp',
            'SEQUENCE:${sequence + 1}',
            ...timeLines(e),
            'SUMMARY:${escape(e.title)}',
            if (e.location.isNotEmpty) 'LOCATION:${escape(e.location)}',
            if (e.notes.isNotEmpty) 'DESCRIPTION:${escape(e.notes)}',
          ]);
          inEvent = false;
          done = true;
          out.add(line);
          continue;
        }
      }
      if (inEvent && depth == 0 && l != null && replaced.contains(l.name)) {
        if (l.name == 'SEQUENCE') sequence = int.tryParse(l.value.trim()) ?? 0;
        continue;
      }
      out.add(line);
    }
    return '${out.map(fold).join('\r\n')}\r\n';
  }

  /// The events of [text] overlapping [from]–[to], repeating ones worked
  /// out into single times, sorted by start.
  static List<CalendarEvent> expand(
    String text,
    DateTime from,
    DateTime to, {
    String idPrefix = '',
    String calendarId = '',
    String calendarName = '',
    String? etag,
  }) {
    final all = parse(text).where((e) => e.start != null).toList();
    // Single times moved or changed on their own, by series and time.
    final overrides = <String, IcsEvent>{
      for (final e in all)
        if (e.recurrenceId != null)
          '${e.uid}@${e.recurrenceId!.at.millisecondsSinceEpoch}': e,
    };
    final out = <CalendarEvent>[];
    CalendarEvent make(
      IcsEvent e,
      DateTime start,
      DateTime end,
      bool day, {
      bool repeats = false,
    }) => CalendarEvent(
      id: idPrefix.isEmpty ? e.uid : idPrefix,
      title: e.text('SUMMARY').isEmpty ? '(no title)' : e.text('SUMMARY'),
      start: start,
      end: end,
      allDay: day,
      location: e.text('LOCATION'),
      notes: e.text('DESCRIPTION'),
      calendarId: calendarId,
      calendarName: calendarName,
      repeats: repeats,
      etag: etag,
    );
    bool overlaps(DateTime s, DateTime e) =>
        s.isBefore(to) && (e.isAfter(from) || (s == e && !s.isBefore(from)));
    for (final e in all) {
      if (e.cancelled) continue;
      final start = e.start!;
      final end = e.endFor(start.at, start.day);
      if (e.recurrenceId != null) {
        if (overlaps(start.at, end)) {
          out.add(make(e, start.at, end, start.day, repeats: true));
        }
        continue;
      }
      final rule = e.first('RRULE')?.value;
      if (rule == null) {
        if (overlaps(start.at, end)) out.add(make(e, start.at, end, start.day));
        continue;
      }
      final skip = {for (final x in e.exdates) x.millisecondsSinceEpoch};
      final length = end.difference(start.at);
      final days = start.day ? _daysBetween(start.at, end) : 0;
      for (final at in RRule.parse(rule).times(start.at, to)) {
        final key = at.millisecondsSinceEpoch;
        if (skip.contains(key) || overrides.containsKey('${e.uid}@$key')) {
          continue;
        }
        final until = start.day
            ? DateTime(at.year, at.month, at.day + days)
            : at.add(length);
        if (overlaps(at, until)) {
          out.add(make(e, at, until, start.day, repeats: true));
        }
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

/// A repeat rule (RRULE) of the common kinds: daily, weekly on some days,
/// monthly on a date or on "the second Tuesday", yearly; with an interval,
/// a count or an end date.
class RRule {
  RRule({
    required this.freq,
    this.interval = 1,
    this.count,
    this.until,
    this.byDay = const [],
    this.byMonthDay,
  });

  final String freq;
  final int interval;
  final int? count;
  final DateTime? until;

  /// Weekdays (1 = Monday) with an optional position in the month (2 =
  /// the second, -1 = the last).
  final List<({int weekday, int? nth})> byDay;
  final int? byMonthDay;

  static const _days = {
    'MO': 1,
    'TU': 2,
    'WE': 3,
    'TH': 4,
    'FR': 5,
    'SA': 6,
    'SU': 7,
  };

  static RRule parse(String rule) {
    final parts = <String, String>{};
    for (final p in rule.split(';')) {
      final eq = p.indexOf('=');
      if (eq > 0) parts[p.substring(0, eq).toUpperCase()] = p.substring(eq + 1);
    }
    final until = parts['UNTIL'];
    return RRule(
      freq: (parts['FREQ'] ?? 'DAILY').toUpperCase(),
      interval: (int.tryParse(parts['INTERVAL'] ?? '') ?? 1).clamp(1, 1000),
      count: int.tryParse(parts['COUNT'] ?? ''),
      until: until == null
          ? null
          : Ics.readTime(IcsLine('UNTIL', {}, until))?.at,
      byDay: [
        for (final d in (parts['BYDAY'] ?? '').split(','))
          if (RegExp(
                r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$',
              ).firstMatch(d.trim().toUpperCase())
              case final m?)
            (weekday: _days[m[2]]!, nth: int.tryParse(m[1] ?? '')),
      ],
      byMonthDay: int.tryParse((parts['BYMONTHDAY'] ?? '').split(',').first),
    );
  }

  /// The start of every time, from [first] on, until the rule ends or a
  /// time passes [before]. Capped, so a broken rule can't run forever.
  Iterable<DateTime> times(DateTime first, DateTime before) sync* {
    var made = 0;
    var steps = 0;
    final endOfUntil = until;
    bool ended(DateTime t) =>
        (count != null && made >= count!) ||
        (endOfUntil != null && t.isAfter(endOfUntil)) ||
        !t.isBefore(before);
    for (var n = 0; steps < 20000; n++) {
      steps++;
      final batch = _period(first, n);
      if (batch.isEmpty) {
        // A month without that date: go on to the next one.
        if (_periodStart(first, n).isAfter(before)) return;
        continue;
      }
      for (final t in batch) {
        if (t.isBefore(first)) continue;
        if (ended(t)) return;
        made++;
        yield t;
      }
    }
  }

  DateTime _at(DateTime base, int y, int m, int d) =>
      DateTime(y, m, d, base.hour, base.minute, base.second);

  DateTime _periodStart(DateTime f, int n) => switch (freq) {
    'YEARLY' => DateTime(f.year + n * interval),
    'MONTHLY' => DateTime(f.year, f.month + n * interval),
    'WEEKLY' => DateTime(f.year, f.month, f.day + n * 7 * interval),
    _ => DateTime(f.year, f.month, f.day + n * interval),
  };

  /// The times in the [n]th period after [f]'s, in order.
  List<DateTime> _period(DateTime f, int n) {
    switch (freq) {
      case 'WEEKLY':
        if (byDay.isEmpty) {
          return [_at(f, f.year, f.month, f.day + n * 7 * interval)];
        }
        // The week (Monday first) n intervals on.
        final monday = f.day - (f.weekday - 1) + n * 7 * interval;
        final days = byDay.map((d) => d.weekday).toSet().toList()..sort();
        return [for (final d in days) _at(f, f.year, f.month, monday + d - 1)];
      case 'MONTHLY':
        final y = f.year, m = f.month + n * interval;
        final norm = DateTime(y, m);
        if (byDay.isNotEmpty) {
          final out = <DateTime>[];
          for (final d in byDay) {
            if (_nthWeekday(norm.year, norm.month, d.weekday, d.nth ?? 1)
                case final day?) {
              out.add(_at(f, norm.year, norm.month, day));
            }
          }
          return out..sort();
        }
        final want = byMonthDay ?? f.day;
        final last = DateTime(norm.year, norm.month + 1, 0).day;
        final day = want < 0 ? last + want + 1 : want;
        if (day < 1 || day > last) return const [];
        return [_at(f, norm.year, norm.month, day)];
      case 'YEARLY':
        final y = f.year + n * interval;
        final t = _at(f, y, f.month, f.day);
        return t.month == f.month ? [t] : const [];
      default:
        return [_at(f, f.year, f.month, f.day + n * interval)];
    }
  }

  /// The day of the month of the [nth] [weekday] (negative counts from the
  /// end), or null when the month has none.
  static int? _nthWeekday(int year, int month, int weekday, int nth) {
    final last = DateTime(year, month + 1, 0).day;
    final days = [
      for (var d = 1; d <= last; d++)
        if (DateTime(year, month, d).weekday == weekday) d,
    ];
    final i = nth > 0 ? nth - 1 : days.length + nth;
    return i >= 0 && i < days.length ? days[i] : null;
  }
}
