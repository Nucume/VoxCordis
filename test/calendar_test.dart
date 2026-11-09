import 'dart:convert';
import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:companion/services/calendar/caldav.dart';
import 'package:companion/services/calendar/calendar_event.dart';
import 'package:companion/services/calendar/calendar_service.dart';
import 'package:companion/services/calendar/calendar_tools.dart';
import 'package:companion/services/calendar/google_calendar.dart';
import 'package:companion/services/calendar/ics.dart';
import 'package:companion/services/calendar/link_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A calendar kept in memory.
class _FakeSource implements CalendarSource {
  _FakeSource(this.items);

  final List<CalendarEvent> items;
  @override
  bool get canWrite => true;
  final added = <CalendarEvent>[];
  final updated = <CalendarEvent>[];
  final deleted = <CalendarEvent>[];

  @override
  Future<List<CalendarInfo>> calendars() async => const [
    CalendarInfo(id: 'main', name: 'Personal', primary: true),
    CalendarInfo(id: 'work', name: 'Work'),
  ];

  @override
  Future<List<CalendarEvent>> events(
    DateTime from,
    DateTime to, {
    List<String> calendarIds = const [],
  }) async => [
    for (final e in items)
      if (e.start.isBefore(to) && e.end.isAfter(from)) e,
  ];

  @override
  Future<CalendarEvent> add(CalendarEvent event, {String? calendarId}) async {
    final saved = CalendarEvent(
      id: 'new${added.length}',
      title: event.title,
      start: event.start,
      end: event.end,
      allDay: event.allDay,
      location: event.location,
      calendarId: calendarId ?? '',
    );
    added.add(saved);
    return saved;
  }

  @override
  Future<CalendarEvent> update(CalendarEvent event) async {
    updated.add(event);
    return event;
  }

  @override
  Future<void> delete(CalendarEvent event) async => deleted.add(event);
}

class _Service extends CalendarService {
  _Service(this.fake, AppSettings Function() settings)
    : super(settings: settings);
  final CalendarSource fake;

  @override
  Future<CalendarSource?> source() async => fake;
}

Map<String, Object?> _json(String s) => jsonDecode(s) as Map<String, Object?>;

void main() {
  group('Ics', () {
    test('reads times, escapes, folds and durations', () {
      const text =
          'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:a\r\n'
          'DTSTART:20261109T130000Z\r\n'
          'DURATION:PT1H30M\r\n'
          'SUMMARY:Dentist\\, Dr. Lee\r\n'
          'DESCRIPTION:Bring the\\ncard and a very long note that goes on \r\n'
          ' and on\r\n'
          'BEGIN:VALARM\r\n'
          'SUMMARY:Not the title\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:b\r\n'
          'DTSTART;VALUE=DATE:20261110\r\n'
          'SUMMARY:Holiday\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final events = Ics.expand(
        text,
        DateTime(2026, 11, 1),
        DateTime(2026, 12, 1),
      );
      expect(events, hasLength(2));
      final a = events[0];
      expect(a.title, 'Dentist, Dr. Lee');
      expect(a.start, DateTime.utc(2026, 11, 9, 13).toLocal());
      expect(a.end.difference(a.start), const Duration(minutes: 90));
      expect(
        a.notes,
        'Bring the\ncard and a very long note that goes on and on',
      );
      final b = events[1];
      expect(b.allDay, isTrue);
      expect(b.end, DateTime(2026, 11, 11));
      expect(b.when, '2026-11-10 (all day)');
    });

    test('works out weekly repeats with skipped days and changed times', () {
      const text =
          'BEGIN:VEVENT\n'
          'UID:gym\n'
          'DTSTART:20261102T180000\n'
          'DTEND:20261102T190000\n'
          'RRULE:FREQ=WEEKLY;BYDAY=MO,TH;COUNT=6\n'
          'EXDATE:20261105T180000\n'
          'SUMMARY:Gym\n'
          'END:VEVENT\n'
          'BEGIN:VEVENT\n'
          'UID:gym\n'
          'RECURRENCE-ID:20261109T180000\n'
          'DTSTART:20261109T200000\n'
          'DTEND:20261109T210000\n'
          'SUMMARY:Gym (late)\n'
          'END:VEVENT\n';
      final events = Ics.expand(
        text,
        DateTime(2026, 11, 1),
        DateTime(2026, 12, 31),
      );
      expect(
        [for (final e in events) '${CalendarEvent.stamp(e.start)} ${e.title}'],
        [
          '2026-11-02 18:00 Gym',
          // The 5th is skipped; the 9th was moved to 20:00.
          '2026-11-09 20:00 Gym (late)',
          '2026-11-12 18:00 Gym',
          '2026-11-16 18:00 Gym',
          '2026-11-19 18:00 Gym',
        ],
      );
      expect(events.every((e) => e.repeats), isTrue);
    });

    test('monthly on the second Tuesday and on the last day', () {
      final second = RRule.parse(
        'FREQ=MONTHLY;BYDAY=2TU',
      ).times(DateTime(2026, 11, 10, 9), DateTime(2027, 2, 1)).toList();
      expect(second, [
        DateTime(2026, 11, 10, 9),
        DateTime(2026, 12, 8, 9),
        DateTime(2027, 1, 12, 9),
      ]);
      final last = RRule.parse(
        'FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20270301',
      ).times(DateTime(2026, 11, 30), DateTime(2028)).toList();
      expect(last, [
        DateTime(2026, 11, 30),
        DateTime(2026, 12, 31),
        DateTime(2027, 1, 31),
        DateTime(2027, 2, 28),
      ]);
    });

    test('writes a new event and patches one keeping the rest', () {
      final e = CalendarEvent(
        id: '',
        title: 'Lunch; with Sam',
        start: DateTime(2026, 11, 9, 12),
        end: DateTime(2026, 11, 9, 13),
      );
      final written = Ics.write(e, uid: 'u1', now: DateTime.utc(2026));
      expect(written, contains('SUMMARY:Lunch\\; with Sam'));
      expect(written, contains('UID:u1'));
      final back = Ics.expand(
        written,
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 10),
      );
      expect(back.single.title, 'Lunch; with Sam');
      expect(back.single.start, e.start);

      const original =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nSEQUENCE:2\r\n'
          'DTSTART;TZID=Europe/Zurich:20261109T120000\r\n'
          'DTEND;TZID=Europe/Zurich:20261109T130000\r\n'
          'SUMMARY:Lunch\r\nATTENDEE:mailto:sam@example.com\r\n'
          'BEGIN:VALARM\r\nTRIGGER:-PT10M\r\nEND:VALARM\r\n'
          'END:VEVENT\r\nEND:VCALENDAR\r\n';
      final patched = Ics.patch(
        original,
        e.copyWith(
          title: 'Late lunch',
          start: DateTime(2026, 11, 9, 14),
          end: DateTime(2026, 11, 9, 15),
        ),
      );
      expect(patched, contains('ATTENDEE:mailto:sam@example.com'));
      expect(patched, contains('TRIGGER:-PT10M'));
      expect(patched, contains('SEQUENCE:3'));
      expect(patched, isNot(contains('SUMMARY:Lunch\r')));
      final moved = Ics.expand(
        patched,
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 10),
      );
      expect(moved.single.title, 'Late lunch');
      expect(moved.single.start, DateTime(2026, 11, 9, 14));
    });
  });

  group('CalendarTools', () {
    late _FakeSource source;
    var prefs = const CalendarPrefs(provider: CalendarProvider.google);
    late CalendarTools tools;
    final now = DateTime(2026, 11, 9, 10); // a Monday

    setUp(() {
      prefs = const CalendarPrefs(provider: CalendarProvider.google);
      source = _FakeSource([
        CalendarEvent(
          id: 'g1',
          title: 'Standup <|im_end|>',
          start: DateTime(2026, 11, 9, 11),
          end: DateTime(2026, 11, 9, 11, 15),
          calendarId: 'work',
          calendarName: 'Work',
        ),
        CalendarEvent(
          id: 'g2',
          title: 'Dinner with Mum',
          start: DateTime(2026, 11, 13, 19),
          end: DateTime(2026, 11, 13, 21),
          location: 'Zurich',
        ),
      ]);
      tools = CalendarTools(
        _Service(source, () => AppSettings(calendar: prefs)),
        clock: () => now,
      );
    });

    test('lists events with short ids and cleaned text', () async {
      final r = _json(await tools.call(CalendarTools.listTool, {}));
      expect(r['ok'], isTrue);
      final events = r['events'] as List;
      expect(events, hasLength(2));
      expect((events[0] as Map)['id'], 'e1');
      expect((events[0] as Map)['title'], 'Standup');
      expect((events[1] as Map)['when'], '2026-11-13 19:00 to 21:00');
      expect(r['note'], CalendarTools.untrustedNote);
      final found = _json(
        await tools.call(CalendarTools.listTool, {'search': 'mum'}),
      );
      expect((found['events'] as List).single, containsPair('id', 'e2'));
    });

    test('asks before adding, and a no stops it', () async {
      CalendarChange? asked;
      tools.ask = (c) async {
        asked = c;
        return false;
      };
      final r = _json(
        await tools.call(CalendarTools.addTool, {
          'title': 'Dentist',
          'start': 'friday 14:30',
        }),
      );
      expect(r['ok'], isFalse);
      expect(asked?.event.start, DateTime(2026, 11, 13, 14, 30));
      expect(asked?.event.end, DateTime(2026, 11, 13, 15, 30));
      expect(asked?.calendar, 'Personal');
      expect(source.added, isEmpty);

      tools.ask = (_) async => true;
      final ok = _json(
        await tools.call(CalendarTools.addTool, {
          'title': 'Dentist',
          'start': '2026-11-13 14:30',
          'end': '15:00',
        }),
      );
      expect(ok['ok'], isTrue);
      expect(source.added.single.end, DateTime(2026, 11, 13, 15));
      expect(source.added.single.calendarId, 'main');
    });

    test('all-day events from a date', () async {
      tools.ask = (_) async => true;
      await tools.call(CalendarTools.addTool, {
        'title': 'Trip',
        'start': '2026-11-20',
        'end': '2026-11-22',
      });
      final e = source.added.single;
      expect(e.allDay, isTrue);
      expect(e.start, DateTime(2026, 11, 20));
      expect(e.end, DateTime(2026, 11, 23));
    });

    test('moves an event keeping its length, and deletes one', () async {
      prefs = prefs.copyWith(askFirst: false);
      await tools.call(CalendarTools.listTool, {});
      final r = _json(
        await tools.call(CalendarTools.changeTool, {
          'id': 'e2',
          'start': 'saturday 18:00',
        }),
      );
      expect(r['ok'], isTrue, reason: '$r');
      final moved = source.updated.single;
      expect(moved.id, 'g2');
      expect(moved.start, DateTime(2026, 11, 14, 18));
      expect(moved.end, DateTime(2026, 11, 14, 20));
      expect(moved.location, 'Zurich');

      final d = _json(await tools.call(CalendarTools.deleteTool, {'id': 'e1'}));
      expect(d['ok'], isTrue);
      expect(source.deleted.single.id, 'g1');
      final again = _json(
        await tools.call(CalendarTools.deleteTool, {'id': 'e1'}),
      );
      expect(again['ok'], isFalse);
    });

    test('unknown ids point back to calendar_events', () async {
      final r = _json(await tools.call(CalendarTools.deleteTool, {'id': 'e9'}));
      expect(r['error'], contains('calendar_events'));
    });

    test('automations never change without asking; web text forces a '
        'question', () async {
      final r = _json(
        await tools.call(CalendarTools.addTool, {
          'title': 'X',
          'start': 'tomorrow 9:00',
        }, unattended: true),
      );
      expect(r['ok'], isFalse);
      expect(source.added, isEmpty);

      prefs = prefs.copyWith(askFirst: false);
      var asked = 0;
      tools.ask = (_) async {
        asked++;
        return true;
      };
      await tools.call(CalendarTools.addTool, {
        'title': 'X',
        'start': 'tomorrow 9:00',
      });
      expect(asked, 0);
      await tools.call(CalendarTools.addTool, {
        'title': 'Y',
        'start': 'tomorrow 9:00',
      }, mustAsk: true);
      expect(asked, 1);
      expect(source.added, hasLength(2));
    });

    test('offers only reading for a link, nothing when unconnected', () {
      List<String> names(CalendarPrefs c) => [
        for (final t in CalendarTools.definitionsFor(AppSettings(calendar: c)))
          (t['function'] as Map)['name'] as String,
      ];
      expect(names(const CalendarPrefs()), isEmpty);
      expect(names(const CalendarPrefs(provider: CalendarProvider.link)), [
        CalendarTools.listTool,
      ]);
      expect(
        names(const CalendarPrefs(provider: CalendarProvider.caldav)).toSet(),
        CalendarTools.names,
      );
    });

    test('reads the usual ways of saying a time', () {
      ({DateTime at, bool day})? t(String s) => CalendarTools.parseTime(s, now);
      expect(t('friday 18:30')?.at, DateTime(2026, 11, 13, 18, 30));
      expect(t('next monday 9:00')?.at, DateTime(2026, 11, 16, 9));
      expect(t('monday')?.at, DateTime(2026, 11, 9));
      expect(t('2026-11-09')?.day, isTrue);
      expect(t('tomorrow 9:00')?.at, DateTime(2026, 11, 10, 9));
      expect(t('in 2 hours')?.at, DateTime(2026, 11, 9, 12));
      expect(t('soonish'), isNull);
    });
  });

  group('CalDAV', () {
    test('finds calendars, reads events, adds and deletes one time of a '
        'repeat', () async {
      final requests = <http.Request>[];
      var stored =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r\r\n'
          'DTSTART:20261110T080000Z\r\nDTEND:20261110T090000Z\r\n'
          'RRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Walk\r\n'
          'END:VEVENT\r\nEND:VCALENDAR\r\n';
      final client = MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        if (req.headers['Authorization'] !=
            'Basic ${base64Encode(utf8.encode('me:pw'))}') {
          return http.Response('', 401);
        }
        if (req.method == 'PROPFIND' && path == '/') {
          return http.Response('', 301, headers: {'location': '/dav/'});
        }
        if (req.method == 'PROPFIND' && path == '/dav/') {
          return http.Response(
            '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href>'
            '<d:propstat><d:prop><d:current-user-principal>'
            '<d:href>/dav/me/</d:href></d:current-user-principal>'
            '</d:prop></d:propstat></d:response></d:multistatus>',
            207,
          );
        }
        if (req.method == 'PROPFIND' &&
            path == '/dav/me/' &&
            req.headers['Depth'] == '0') {
          return http.Response(
            '<d:multistatus xmlns:d="DAV:" '
            'xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response>'
            '<d:href>/dav/me/</d:href><d:propstat><d:prop>'
            '<c:calendar-home-set><d:href>/dav/cals/</d:href>'
            '</c:calendar-home-set></d:prop></d:propstat></d:response>'
            '</d:multistatus>',
            207,
          );
        }
        if (req.method == 'PROPFIND' && path == '/dav/cals/') {
          return http.Response(
            '<d:multistatus xmlns:d="DAV:" '
            'xmlns:c="urn:ietf:params:xml:ns:caldav">'
            '<d:response><d:href>/dav/cals/</d:href><d:propstat><d:prop>'
            '<d:resourcetype><d:collection/></d:resourcetype>'
            '</d:prop></d:propstat></d:response>'
            '<d:response><d:href>/dav/cals/home/</d:href><d:propstat>'
            '<d:prop><d:displayname>Home</d:displayname><d:resourcetype>'
            '<d:collection/><c:calendar/></d:resourcetype>'
            '<c:supported-calendar-component-set><c:comp name="VEVENT"/>'
            '</c:supported-calendar-component-set></d:prop></d:propstat>'
            '</d:response>'
            '<d:response><d:href>/dav/cals/tasks/</d:href><d:propstat>'
            '<d:prop><d:displayname>Tasks</d:displayname><d:resourcetype>'
            '<d:collection/><c:calendar/></d:resourcetype>'
            '<c:supported-calendar-component-set><c:comp name="VTODO"/>'
            '</c:supported-calendar-component-set></d:prop></d:propstat>'
            '</d:response></d:multistatus>',
            207,
          );
        }
        if (req.method == 'REPORT') {
          return http.Response(
            '<d:multistatus xmlns:d="DAV:" '
            'xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response>'
            '<d:href>/dav/cals/home/r.ics</d:href><d:propstat><d:prop>'
            '<d:getetag>"1"</d:getetag><c:calendar-data>'
            '${const HtmlEscape().convert(stored)}'
            '</c:calendar-data></d:prop></d:propstat></d:response>'
            '</d:multistatus>',
            207,
          );
        }
        if (req.method == 'GET' && path == '/dav/cals/home/r.ics') {
          return http.Response(stored, 200, headers: {'etag': '"1"'});
        }
        if (req.method == 'PUT') {
          if (path == '/dav/cals/home/r.ics') stored = req.body;
          return http.Response('', 201, headers: {'etag': '"2"'});
        }
        return http.Response('', 404);
      });
      final dav = CalDavSource(
        url: 'cal.example.com',
        user: 'me',
        password: 'pw',
        client: client,
      );
      final cals = await dav.calendars();
      expect(cals.single.name, 'Home');
      expect(cals.single.primary, isTrue);
      expect(cals.single.id, 'https://cal.example.com/dav/cals/home/');

      final events = await dav.events(
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 20),
      );
      expect(events, hasLength(3));
      expect(events.first.id, 'https://cal.example.com/dav/cals/home/r.ics');
      expect(events.first.calendarName, 'Home');

      final added = await dav.add(
        CalendarEvent(
          id: '',
          title: 'Call',
          start: DateTime(2026, 11, 12, 9),
          end: DateTime(2026, 11, 12, 10),
        ),
      );
      final put = requests.lastWhere((r) => r.method == 'PUT');
      expect(put.headers['If-None-Match'], '*');
      expect(put.url.toString(), added.id);
      expect(put.body, contains('SUMMARY:Call'));

      // Deleting the second walk keeps the others.
      await dav.delete(events[1]);
      expect(stored, contains('EXDATE:20261111T080000Z'));
      final left = Ics.expand(
        stored,
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 20),
      );
      expect(left, hasLength(2));

      await expectLater(
        dav.update(events[0].copyWith(title: 'Run')),
        throwsA(isA<CalendarException>()),
      );
    });

    test('a refused password asks to sign in again', () async {
      final dav = CalDavSource(
        url: 'https://cal.example.com/',
        user: 'me',
        password: 'wrong',
        client: MockClient((_) async => http.Response('', 401)),
      );
      await expectLater(
        dav.calendars(),
        throwsA(
          isA<CalendarException>().having((e) => e.signInAgain, 'again', true),
        ),
      );
    });
  });

  group('Google', () {
    test('PKCE challenge matches RFC 7636', () {
      expect(
        GoogleAuth.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('reads a client file', () {
      final c = GoogleClient.fromJson(
        '{"installed":{"client_id":"123-abc.apps.googleusercontent.com",'
        '"client_secret":"s3"}}',
      );
      expect(c?.id, '123-abc.apps.googleusercontent.com');
      expect(c?.secret, 's3');
      expect(GoogleClient.fromJson('{"installed":{"client_id":"x"}}'), isNull);
      expect(GoogleClient.fromJson('nope'), isNull);
    });

    test('uses the built-in client unless the human loaded one', () async {
      final service = CalendarService(settings: () => const AppSettings());
      // Tests run without --dart-define, so there is no built-in client.
      expect(GoogleClient.builtIn, isNull);
      expect(await service.googleClient(), isNull);
      expect(await service.ownGoogleClient(), isFalse);
      expect(
        await service.setGoogleClient(
          '{"installed":{"client_id":"own.apps.googleusercontent.com"}}',
        ),
        isTrue,
      );
      expect(
        (await service.googleClient())?.id,
        'own.apps.googleusercontent.com',
      );
      await service.clearGoogleClient();
      expect((await service.googleClient())?.id, GoogleClient.builtIn?.id);
    });

    test('signs in through the browser and a local address', () async {
      final token = MockClient((req) async {
        expect(req.url.host, 'oauth2.googleapis.com');
        final body = Uri.splitQueryString(req.body);
        expect(body['code'], 'the-code');
        expect(body['code_verifier'], isNotEmpty);
        expect(body['redirect_uri'], startsWith('http://127.0.0.1:'));
        return http.Response(
          jsonEncode({
            'access_token': 'a1',
            'refresh_token': 'r1',
            'expires_in': 3600,
            'scope': GoogleAuth.scopes.join(' '),
          }),
          200,
        );
      });
      final auth = GoogleAuth(
        const GoogleClient(id: 'id.apps.googleusercontent.com', secret: 's'),
        http: token,
      );
      final tokens = await auth.signIn((uri) async {
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        expect(uri.queryParameters['access_type'], 'offline');
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        final state = uri.queryParameters['state'];
        // The browser coming back, after a stray request.
        final web = HttpClient();
        Future<void> visit(Uri u) async {
          final r = await (await web.getUrl(u)).close();
          await r.drain<void>();
        }

        Future(() async {
          await visit(redirect.replace(path: '/favicon.ico'));
          await visit(
            redirect.replace(
              queryParameters: {'code': 'the-code', 'state': state},
            ),
          );
          web.close();
        }).ignore();
        return true;
      });
      expect(tokens.refresh, 'r1');
      expect(tokens.access, 'a1');
    });

    test('lists events, adds and deletes through the API', () async {
      final calls = <String>[];
      final api = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.host == 'oauth2.googleapis.com') {
          return http.Response(
            jsonEncode({'access_token': 'a2', 'expires_in': 3600}),
            200,
          );
        }
        expect(req.headers['Authorization'], 'Bearer a2');
        if (req.url.path.endsWith('/calendarList')) {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'me@example.com',
                  'summary': 'me@example.com',
                  'primary': true,
                  'accessRole': 'owner',
                },
                {
                  'id': 'holidays',
                  'summary': 'Holidays',
                  'accessRole': 'reader',
                },
              ],
            }),
            200,
          );
        }
        if (req.method == 'GET') {
          final cal = req.url.pathSegments[3];
          return http.Response(
            jsonEncode({
              'items': cal == 'holidays'
                  ? [
                      {
                        'id': 'h1',
                        'summary': 'Holiday',
                        'start': {'date': '2026-11-11'},
                        'end': {'date': '2026-11-12'},
                      },
                    ]
                  : [
                      {
                        'id': 'x1_20261110',
                        'summary': 'Yoga',
                        'recurringEventId': 'x1',
                        'start': {'dateTime': '2026-11-10T07:00:00Z'},
                        'end': {'dateTime': '2026-11-10T08:00:00Z'},
                      },
                      {'id': 'gone', 'status': 'cancelled'},
                    ],
            }),
            200,
          );
        }
        if (req.method == 'POST') {
          final body = jsonDecode(req.body) as Map;
          expect(body['start'], {'date': '2026-11-20'});
          return http.Response(jsonEncode({...body, 'id': 'n1'}), 200);
        }
        if (req.method == 'DELETE') return http.Response('', 204);
        return http.Response('', 404);
      });
      final google = GoogleSource(
        auth: GoogleAuth(
          const GoogleClient(id: 'id.apps.googleusercontent.com', secret: ''),
          http: api,
        ),
        refreshToken: 'r1',
        client: api,
      );
      final events = await google.events(
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 16),
      );
      expect([for (final e in events) e.title], ['Yoga', 'Holiday']);
      expect(events[0].repeats, isTrue);
      expect(events[0].calendarId, 'me@example.com');
      expect(events[1].allDay, isTrue);
      expect((await google.calendars())[1].writable, isFalse);

      final added = await google.add(
        CalendarEvent(
          id: '',
          title: 'Trip',
          start: DateTime(2026, 11, 20),
          end: DateTime(2026, 11, 21),
          allDay: true,
        ),
      );
      expect(added.id, 'n1');
      expect(added.calendarId, 'me@example.com');
      await google.delete(events[0]);
      expect(
        calls.last,
        'DELETE /calendar/v3/calendars/me%40example.com/events/x1_20261110',
      );
      // One sign-in refresh for all of it.
      expect(calls.where((c) => c.contains('/token')), hasLength(1));
    });
  });

  test('a private link is read-only and cached', () async {
    var fetched = 0;
    final link = LinkSource(
      'webcal://example.com/basic.ics',
      client: MockClient((req) async {
        fetched++;
        expect(req.url.scheme, 'https');
        return http.Response(
          'BEGIN:VCALENDAR\nX-WR-CALNAME:Family\nBEGIN:VEVENT\nUID:1\n'
          'DTSTART:20261109T100000\nDTEND:20261109T110000\nSUMMARY:Brunch\n'
          'END:VEVENT\nEND:VCALENDAR\n',
          200,
        );
      }),
    );
    expect((await link.calendars()).single.name, 'Family');
    final e = await link.events(DateTime(2026, 11, 9), DateTime(2026, 11, 10));
    expect(e.single.title, 'Brunch');
    expect(fetched, 1);
    expect(link.canWrite, isFalse);
    await expectLater(link.delete(e.single), throwsA(isA<CalendarException>()));
  });

  test('calendar settings survive a save and keep no secrets', () {
    const c = CalendarPrefs(
      provider: CalendarProvider.caldav,
      askFirst: false,
      account: 'me',
      caldavUrl: 'https://cal.example.com/',
      caldavUser: 'me',
      calendars: ['a'],
      writeTo: 'a',
    );
    final json = const AppSettings(calendar: c).toJson();
    final back = AppSettings.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, Object?>,
    ).calendar;
    expect(back.toJson(), c.toJson());
    expect(jsonEncode(json), isNot(contains('password')));
    expect(AppSettings.fromJson(const {}).calendar.connected, isFalse);
    expect(AppSettings.fromJson(const {}).calendar.askFirst, isTrue);
  });

  test(
    'connecting a link keeps it secret and disconnecting forgets it',
    () async {
      var settings = const AppSettings();
      final service = CalendarService(
        settings: () => settings,
        client: MockClient(
          (_) async => http.Response(
            'BEGIN:VCALENDAR\nX-WR-CALNAME:Mine\nEND:VCALENDAR\n',
            200,
          ),
        ),
      );
      final r = await service.connectLink('https://example.com/private.ics');
      settings = settings.copyWith(calendar: r.prefs);
      expect(r.prefs.provider, CalendarProvider.link);
      expect(r.prefs.account, 'Mine');
      expect(jsonEncode(settings.toJson()), isNot(contains('private.ics')));
      expect(await service.source(), isA<LinkSource>());
      settings = settings.copyWith(calendar: await service.disconnect());
      expect(settings.calendar.connected, isFalse);
      expect(await service.source(), isNull);
    },
  );
}
