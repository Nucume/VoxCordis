/// One calendar the human has, as a source lists it.
class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.name,
    this.primary = false,
    this.writable = true,
  });

  /// The source's own id: a Google calendar id, or a CalDAV collection URL.
  final String id;
  final String name;

  /// The account's main calendar, where new events go by default.
  final bool primary;

  /// False for calendars only shared to read (holidays, a friend's).
  final bool writable;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (primary) 'primary': true,
    if (!writable) 'writable': false,
  };

  factory CalendarInfo.fromJson(Map<String, Object?> json) => CalendarInfo(
    id: '${json['id']}',
    name: '${json['name'] ?? json['id']}',
    primary: json['primary'] == true,
    writable: json['writable'] != false,
  );
}

/// One event (or one time of a repeating event) in the human's calendar.
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.notes = '',
    this.calendarId = '',
    this.calendarName = '',
    this.repeats = false,
    this.etag,
  });

  /// What the source needs to find it again: a Google event id, or the
  /// CalDAV resource's URL.
  final String id;
  final String title;

  /// Local times. For an all-day event, midnight of the first day and of
  /// the day after the last.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;
  final String notes;
  final String calendarId;
  final String calendarName;

  /// This is one time of a repeating event.
  final bool repeats;

  /// The version the server last gave, so a change can't overwrite one made
  /// meanwhile elsewhere (CalDAV).
  final String? etag;

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? location,
    String? notes,
  }) => CalendarEvent(
    id: id,
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    allDay: allDay ?? this.allDay,
    location: location ?? this.location,
    notes: notes ?? this.notes,
    calendarId: calendarId,
    calendarName: calendarName,
    repeats: repeats,
    etag: etag,
  );

  /// `2026-11-09 14:00`, or `2026-11-09` for a day.
  static String stamp(DateTime t, {bool day = false}) {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = '${t.year}-${two(t.month)}-${two(t.day)}';
    return day ? d : '$d ${two(t.hour)}:${two(t.minute)}';
  }

  /// The last day of an all-day event (its [end] is the day after).
  DateTime get lastDay {
    final d = end.subtract(const Duration(days: 1));
    return d.isBefore(start) ? start : d;
  }

  /// When it is, in words a person reads: "2026-11-09 14:00 to 15:30",
  /// "2026-11-09 (all day)".
  String get when {
    if (allDay) {
      final last = lastDay;
      return CalDay.sameDay(start, last)
          ? '${stamp(start, day: true)} (all day)'
          : '${stamp(start, day: true)} to ${stamp(last, day: true)} (all day)';
    }
    final sameDay = CalDay.sameDay(start, end);
    final endText = sameDay ? stamp(end).substring(11) : stamp(end);
    return '${stamp(start)} to $endText';
  }

  /// What the companion is given. [clean] tidies text other people wrote
  /// (an invite can say anything).
  Map<String, Object?> toJson({String Function(String)? clean}) {
    final c = clean ?? (String s) => s;
    return {
      'id': id,
      'title': c(title),
      'when': when,
      if (location.isNotEmpty) 'location': c(location),
      if (notes.isNotEmpty)
        'notes': c(notes.length > 400 ? '${notes.substring(0, 400)}…' : notes),
      if (calendarName.isNotEmpty) 'calendar': calendarName,
      if (repeats) 'repeats': true,
    };
  }
}

/// Day helpers, without Flutter's material import.
abstract final class CalDay {
  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// What a calendar can do. [CalendarService] picks one from Settings.
abstract class CalendarSource {
  /// The calendars there are.
  Future<List<CalendarInfo>> calendars();

  /// Events overlapping [from]–[to] in [calendarIds] (all when empty),
  /// repeating ones as single times, sorted by start.
  Future<List<CalendarEvent>> events(
    DateTime from,
    DateTime to, {
    List<String> calendarIds = const [],
  });

  /// Adds [event] to [calendarId] (null: the main calendar) and returns it
  /// as saved, with its id.
  Future<CalendarEvent> add(CalendarEvent event, {String? calendarId});

  /// Saves [event], found by its id, with its new fields.
  Future<CalendarEvent> update(CalendarEvent event);

  /// Deletes [event]; for one time of a repeating event, only that time.
  Future<void> delete(CalendarEvent event);

  /// False for a read-only private link.
  bool get canWrite;
}

/// What went wrong talking to a calendar, in words for the human.
class CalendarException implements Exception {
  const CalendarException(this.message, {this.signInAgain = false});
  final String message;

  /// The sign-in was refused or ran out: Settings should offer to connect
  /// again.
  final bool signInAgain;

  @override
  String toString() => message;
}
