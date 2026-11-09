import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import 'calendar_event.dart';
import 'ics.dart';

/// A CalDAV server (RFC 4791): iCloud, Fastmail, Nextcloud, mailbox.org,
/// Radicale… Signed in with a user name and an app password over HTTPS
/// basic auth.
class CalDavSource implements CalendarSource {
  CalDavSource({
    required this.url,
    required this.user,
    required this.password,
    http.Client? client,
  }) : _http = client ?? http.Client();

  /// The address the human gave: the server, their account or a calendar.
  final String url;
  final String user;
  final String password;
  final http.Client _http;

  List<CalendarInfo>? _found;

  static const _dav = 'DAV:';
  static const _cal = 'urn:ietf:params:xml:ns:caldav';

  @override
  bool get canWrite => true;

  /// The address as typed: `caldav.icloud.com` gets https:// in front.
  static Uri normalise(String raw) {
    var t = raw.trim();
    if (!t.contains('://')) t = 'https://$t';
    final u = Uri.parse(t);
    return u.path.isEmpty ? u.replace(path: '/') : u;
  }

  Map<String, String> get _auth => {
    'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}',
  };

  /// One request, following redirects by hand (the http client only
  /// follows them for GET).
  Future<http.Response> _send(
    String method,
    Uri uri, {
    String? body,
    Map<String, String> headers = const {},
  }) async {
    var at = uri;
    for (var hop = 0; hop < 6; hop++) {
      final req = http.Request(method, at)
        ..followRedirects = false
        ..headers.addAll({..._auth, ...headers});
      if (body != null) {
        req.headers['Content-Type'] ??= 'application/xml; charset=utf-8';
        req.body = body;
      }
      final res = await http.Response.fromStream(
        await _http.send(req).timeout(const Duration(seconds: 30)),
      );
      final next = res.headers['location'];
      if ({301, 302, 303, 307, 308}.contains(res.statusCode) && next != null) {
        at = at.resolve(next);
        continue;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const CalendarException(
          'The calendar server refused the user name or app password.',
          signInAgain: true,
        );
      }
      return res;
    }
    throw const CalendarException('The calendar server kept redirecting.');
  }

  Future<XmlDocument> _propRequest(
    String method,
    Uri uri,
    String body, {
    String depth = '0',
  }) async {
    final res = await _send(method, uri, body: body, headers: {'Depth': depth});
    if (res.statusCode != 207) {
      throw CalendarException(
        'The calendar server answered ${res.statusCode} to $method '
        '${uri.path}.',
      );
    }
    try {
      return XmlDocument.parse(utf8.decode(res.bodyBytes));
    } on XmlException {
      throw const CalendarException(
        'The calendar server sent something that isn\'t CalDAV.',
      );
    }
  }

  static Iterable<XmlElement> _all(XmlNode n, String ns, String name) => n
      .descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == name && (e.name.namespaceUri ?? ns) == ns);

  static String? _href(XmlNode n, String ns, String prop) {
    for (final p in _all(n, ns, prop)) {
      final h = _all(p, _dav, 'href').firstOrNull?.innerText.trim();
      if (h != null && h.isNotEmpty) return h;
    }
    return null;
  }

  static const _findProps =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
      '<d:prop><d:current-user-principal/><c:calendar-home-set/>'
      '<d:resourcetype/></d:prop></d:propfind>';

  static const _listProps =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
      '<d:prop><d:displayname/><d:resourcetype/>'
      '<c:supported-calendar-component-set/>'
      '<d:current-user-privilege-set/></d:prop></d:propfind>';

  /// Finds the calendars: from the address to the account (principal), to
  /// where its calendars live (home), to the calendars.
  @override
  Future<List<CalendarInfo>> calendars() async {
    if (_found case final found?) return found;
    final start = normalise(url);
    final tries = [
      start,
      if (start.path == '/') start.replace(path: '/.well-known/caldav'),
    ];
    Uri? home;
    CalendarException? last;
    for (final at in tries) {
      try {
        final doc = await _propRequest('PROPFIND', at, _findProps);
        if (_all(doc, _cal, 'calendar').isNotEmpty &&
            _all(doc, _dav, 'response').length == 1) {
          // The address is a calendar itself.
          return _found = await _list(at, depth: '0');
        }
        if (_href(doc, _cal, 'calendar-home-set') case final h?) {
          home = at.resolve(h);
          break;
        }
        if (_href(doc, _dav, 'current-user-principal') case final p?) {
          final who = await _propRequest('PROPFIND', at.resolve(p), _findProps);
          if (_href(who, _cal, 'calendar-home-set') case final h?) {
            home = at.resolve(p).resolve(h);
            break;
          }
        }
      } on CalendarException catch (e) {
        if (e.signInAgain) rethrow;
        last = e;
      }
    }
    if (home == null) {
      throw last ??
          const CalendarException(
            'No calendars found at that address. Check it with your '
            'provider\'s CalDAV settings.',
          );
    }
    final list = await _list(home);
    if (list.isEmpty) {
      throw const CalendarException('That account has no calendars.');
    }
    return _found = list;
  }

  Future<List<CalendarInfo>> _list(Uri at, {String depth = '1'}) async {
    final doc = await _propRequest('PROPFIND', at, _listProps, depth: depth);
    final out = <CalendarInfo>[];
    for (final r in _all(doc, _dav, 'response')) {
      if (_all(r, _cal, 'calendar').isEmpty) continue;
      final comps = _all(
        r,
        _cal,
        'comp',
      ).map((c) => c.getAttribute('name')?.toUpperCase()).toList();
      // Task lists and the like hold no events.
      if (comps.isNotEmpty && !comps.contains('VEVENT')) continue;
      final href = _all(r, _dav, 'href').first.innerText.trim();
      final privileges = _all(
        r,
        _dav,
        'privilege',
      ).expand((p) => p.childElements.map((e) => e.name.local)).toSet();
      final name = _all(r, _dav, 'displayname').firstOrNull?.innerText.trim();
      final id = at.resolve(href).toString();
      out.add(
        CalendarInfo(
          id: id,
          name: name == null || name.isEmpty ? _lastSegment(id) : name,
          writable:
              privileges.isEmpty ||
              privileges.contains('write') ||
              privileges.contains('write-content') ||
              privileges.contains('all'),
        ),
      );
    }
    if (out.isNotEmpty) {
      final main = out.firstWhere((c) => c.writable, orElse: () => out.first);
      out[out.indexOf(main)] = CalendarInfo(
        id: main.id,
        name: main.name,
        primary: true,
        writable: main.writable,
      );
    }
    return out;
  }

  static String _lastSegment(String url) {
    final parts = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty);
    return parts.isEmpty ? url : Uri.decodeComponent(parts.last);
  }

  @override
  Future<List<CalendarEvent>> events(
    DateTime from,
    DateTime to, {
    List<String> calendarIds = const [],
  }) async {
    final all = await calendars();
    final pick = calendarIds.isEmpty
        ? all
        : all.where((c) => calendarIds.contains(c.id)).toList();
    final out = <CalendarEvent>[];
    for (final c in pick) {
      out.addAll(await _query(c, from, to));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  Future<List<CalendarEvent>> _query(
    CalendarInfo c,
    DateTime from,
    DateTime to,
  ) async {
    final range = 'start="${Ics.utcValue(from)}" end="${Ics.utcValue(to)}"';
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<c:calendar-query xmlns:d="DAV:" '
        'xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
        '<c:filter><c:comp-filter name="VCALENDAR">'
        '<c:comp-filter name="VEVENT"><c:time-range $range/>'
        '</c:comp-filter></c:comp-filter></c:filter>'
        '</c:calendar-query>';
    final base = Uri.parse(c.id);
    final doc = await _propRequest('REPORT', base, body, depth: '1');
    final out = <CalendarEvent>[];
    for (final r in _all(doc, _dav, 'response')) {
      final data = _all(r, _cal, 'calendar-data').firstOrNull?.innerText;
      if (data == null || data.trim().isEmpty) continue;
      final href = base
          .resolve(_all(r, _dav, 'href').first.innerText.trim())
          .toString();
      out.addAll(
        Ics.expand(
          data,
          from,
          to,
          idPrefix: href,
          calendarId: c.id,
          calendarName: c.name,
          etag: _all(r, _dav, 'getetag').firstOrNull?.innerText.trim(),
        ),
      );
    }
    return out;
  }

  @override
  Future<CalendarEvent> add(CalendarEvent event, {String? calendarId}) async {
    final all = await calendars();
    final target =
        all.where((c) => c.id == calendarId).firstOrNull ??
        all.firstWhere((c) => c.primary, orElse: () => all.first);
    final name = const Uuid().v4();
    final uid = '$name@voxcordis';
    final base = Uri.parse(target.id);
    final dir = base.path.endsWith('/')
        ? base
        : base.replace(path: '${base.path}/');
    final at = dir.resolve('$name.ics');
    final res = await _send(
      'PUT',
      at,
      body: Ics.write(event, uid: uid),
      headers: {
        'Content-Type': 'text/calendar; charset=utf-8',
        'If-None-Match': '*',
      },
    );
    if (res.statusCode >= 300) {
      throw CalendarException(
        'The calendar server answered ${res.statusCode} when adding the '
        'event.',
      );
    }
    return CalendarEvent(
      id: at.toString(),
      title: event.title,
      start: event.start,
      end: event.end,
      allDay: event.allDay,
      location: event.location,
      notes: event.notes,
      calendarId: target.id,
      calendarName: target.name,
      etag: res.headers['etag'],
    );
  }

  /// The event's file as the server has it now, with its version.
  Future<({String ics, String? etag})> _get(Uri at) async {
    final res = await _send('GET', at);
    if (res.statusCode == 404) {
      throw const CalendarException(
        'That event isn\'t there any more. List the events again.',
      );
    }
    if (res.statusCode >= 300) {
      throw CalendarException(
        'The calendar server answered ${res.statusCode} reading the event.',
      );
    }
    return (ics: utf8.decode(res.bodyBytes), etag: res.headers['etag']);
  }

  Future<void> _put(Uri at, String ics, String? etag) async {
    final res = await _send(
      'PUT',
      at,
      body: ics,
      headers: {
        'Content-Type': 'text/calendar; charset=utf-8',
        'If-Match': ?etag,
      },
    );
    if (res.statusCode == 412) {
      throw const CalendarException(
        'The event was changed elsewhere meanwhile. List the events again.',
      );
    }
    if (res.statusCode >= 300) {
      throw CalendarException(
        'The calendar server answered ${res.statusCode} saving the event.',
      );
    }
  }

  @override
  Future<CalendarEvent> update(CalendarEvent event) async {
    final at = Uri.parse(event.id);
    final now = await _get(at);
    if (_repeats(now.ics)) {
      throw const CalendarException(
        'This event repeats. Moving one time of it isn\'t possible from '
        'here yet; your human can change it in their calendar app.',
      );
    }
    await _put(at, Ics.patch(now.ics, event), now.etag);
    return event;
  }

  @override
  Future<void> delete(CalendarEvent event) async {
    final at = Uri.parse(event.id);
    final now = await _get(at);
    if (_repeats(now.ics)) {
      // Only this time goes: the series gets an exception date.
      await _put(at, _withExdate(now.ics, event), now.etag);
      return;
    }
    final res = await _send('DELETE', at, headers: {'If-Match': ?now.etag});
    if (res.statusCode >= 300 && res.statusCode != 404) {
      throw CalendarException(
        'The calendar server answered ${res.statusCode} deleting the event.',
      );
    }
  }

  static bool _repeats(String ics) =>
      Ics.parse(ics).any((e) => e.first('RRULE') != null);

  /// [ics] with [event]'s time added as an exception to its series.
  static String _withExdate(String ics, CalendarEvent event) {
    final line = event.allDay
        ? 'EXDATE;VALUE=DATE:${Ics.dateValue(event.start)}'
        : 'EXDATE:${Ics.utcValue(event.start)}';
    final lines = Ics.unfold(ics);
    final out = <String>[];
    var added = false;
    for (final l in lines) {
      out.add(l);
      if (!added && l.toUpperCase().startsWith('RRULE')) {
        out.add(line);
        added = true;
      }
    }
    return '${out.map(Ics.fold).join('\r\n')}\r\n';
  }
}
