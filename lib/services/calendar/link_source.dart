import 'dart:convert';

import 'package:http/http.dart' as http;

import 'calendar_event.dart';
import 'ics.dart';

/// A calendar's private address (an .ics file Google, Outlook, iCloud or
/// Proton keep up to date). Read-only: the companion can see the events but
/// not change them.
class LinkSource implements CalendarSource {
  LinkSource(this.link, {http.Client? client, DateTime Function()? clock})
    : _http = client ?? http.Client(),
      _clock = clock ?? DateTime.now;

  final String link;
  final http.Client _http;
  final DateTime Function() _clock;

  String? _text;
  DateTime? _fetched;

  /// How long a download is reused before the calendar is fetched again.
  static const keep = Duration(minutes: 15);

  static Uri normalise(String raw) {
    var t = raw.trim();
    if (t.startsWith('webcal://')) t = 'https://${t.substring(9)}';
    if (!t.contains('://')) t = 'https://$t';
    return Uri.parse(t);
  }

  @override
  bool get canWrite => false;

  Future<String> _load() async {
    final now = _clock();
    if (_text case final text? when now.difference(_fetched!) < keep) {
      return text;
    }
    final http.Response res;
    try {
      res = await _http
          .get(normalise(link))
          .timeout(const Duration(seconds: 30));
    } on Exception {
      throw const CalendarException('The calendar link couldn\'t be reached.');
    }
    if (res.statusCode == 404 ||
        res.statusCode == 401 ||
        res.statusCode == 403) {
      throw const CalendarException(
        'The calendar link was refused. It may have been reset: copy it '
        'again from your calendar\'s settings.',
        signInAgain: true,
      );
    }
    if (res.statusCode >= 300) {
      throw CalendarException('The calendar link answered ${res.statusCode}.');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (!text.contains('BEGIN:VCALENDAR')) {
      throw const CalendarException(
        'That link isn\'t a calendar file. Look for the "secret address in '
        'iCal format" or "ICS link" in your calendar\'s settings.',
      );
    }
    _fetched = now;
    return _text = text;
  }

  String _name(String text) {
    final m = RegExp(
      r'^X-WR-CALNAME:(.+)$',
      multiLine: true,
    ).firstMatch(text.replaceAll('\r', ''));
    return m == null ? 'Calendar' : Ics.unescape(m[1]!.trim());
  }

  @override
  Future<List<CalendarInfo>> calendars() async => [
    CalendarInfo(
      id: 'link',
      name: _name(await _load()),
      primary: true,
      writable: false,
    ),
  ];

  @override
  Future<List<CalendarEvent>> events(
    DateTime from,
    DateTime to, {
    List<String> calendarIds = const [],
  }) async {
    final text = await _load();
    return Ics.expand(
      text,
      from,
      to,
      calendarId: 'link',
      calendarName: _name(text),
    );
  }

  static const _readOnly = CalendarException(
    'This calendar is connected with a read-only link, so you can\'t change '
    'it. Your human can connect it with Google sign-in or CalDAV in '
    'Settings → Connections to let you.',
  );

  @override
  Future<CalendarEvent> add(CalendarEvent event, {String? calendarId}) async =>
      throw _readOnly;

  @override
  Future<CalendarEvent> update(CalendarEvent event) async => throw _readOnly;

  @override
  Future<void> delete(CalendarEvent event) async => throw _readOnly;
}
