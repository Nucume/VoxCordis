import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'calendar_event.dart';

/// The app's Google sign-in client: an id and a "secret" that, for a
/// desktop app, isn't one (Google says so; anyone can read it out of the
/// app). Built in with `--dart-define=GOOGLE_CLIENT_ID=…`, or loaded from
/// the JSON file Google Cloud gives for a "Desktop app" client. PKCE
/// protects each sign-in.
class GoogleClient {
  const GoogleClient({required this.id, required this.secret});

  final String id;
  final String secret;

  /// VoxCordis's own client (Google Cloud project "VoxCordis", a Desktop
  /// app client), built into release builds with
  /// `--dart-define=GOOGLE_CLIENT_ID=… --dart-define=GOOGLE_CLIENT_SECRET=…`
  /// from the public repository's secrets. It isn't kept in the source:
  /// GitHub's push protection refuses a Google client secret in a commit to
  /// the public repository. A build without it has no built-in client, and
  /// the human loads Google's client file instead.
  static const _definedId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const _definedSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');

  /// The one this build came with, if any.
  static GoogleClient? get builtIn => _definedId.isNotEmpty
      ? const GoogleClient(id: _definedId, secret: _definedSecret)
      : null;

  /// Reads Google's client file (`{"installed": {"client_id": …}}`).
  static GoogleClient? fromJson(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final inner = (json['installed'] ?? json['web'] ?? json) as Map;
      final id = '${inner['client_id'] ?? ''}'.trim();
      if (!id.endsWith('.apps.googleusercontent.com')) return null;
      return GoogleClient(
        id: id,
        secret: '${inner['client_secret'] ?? ''}'.trim(),
      );
    } on Object {
      return null;
    }
  }

  String toJson() => jsonEncode({
    'installed': {'client_id': id, 'client_secret': secret},
  });
}

/// What a sign-in gave: the long-lived refresh token, and the access token
/// to use now.
class GoogleTokens {
  const GoogleTokens({
    required this.refresh,
    required this.access,
    required this.expires,
    this.scopes = const {},
  });

  final String refresh;
  final String access;
  final DateTime expires;
  final Set<String> scopes;
}

/// Signs in to Google the way desktop apps should (RFC 8252): the system
/// browser opens Google's page, and Google sends the answer back to a
/// one-off address on this computer (127.0.0.1), checked with PKCE so no
/// other program can use it. Nothing goes through a VoxCordis server.
class GoogleAuth {
  GoogleAuth(this.client, {http.Client? http})
    : _http = http ?? _defaultClient();

  final GoogleClient client;
  final http.Client _http;

  static http.Client _defaultClient() => http.Client();

  /// Read and change events; see the list of calendars.
  static const eventsScope = 'https://www.googleapis.com/auth/calendar.events';
  static const listScope =
      'https://www.googleapis.com/auth/calendar.calendarlist.readonly';
  static const scopes = [eventsScope, listScope];

  static const _authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
  static final _tokenUrl = Uri.parse('https://oauth2.googleapis.com/token');
  static final _revokeUrl = Uri.parse('https://oauth2.googleapis.com/revoke');

  static String _random(int bytes) {
    final r = Random.secure();
    return base64UrlEncode(
      List<int>.generate(bytes, (_) => r.nextInt(256)),
    ).replaceAll('=', '');
  }

  static String challengeFor(String verifier) => base64UrlEncode(
    sha256.convert(ascii.encode(verifier)).bytes,
  ).replaceAll('=', '');

  /// The page Google shows, for [redirect] with [state] and [verifier].
  Uri authUri({
    required String redirect,
    required String state,
    required String verifier,
  }) => Uri.parse(_authUrl).replace(
    queryParameters: {
      'client_id': client.id,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'code_challenge': challengeFor(verifier),
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      // Always asks, so Google always hands over a refresh token.
      'prompt': 'consent',
    },
  );

  /// Opens Google's sign-in in the browser with [open] and waits (up to
  /// [wait]) for the human to finish there.
  Future<GoogleTokens> signIn(
    Future<bool> Function(Uri) open, {
    Duration wait = const Duration(minutes: 5),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}';
      final state = _random(16);
      final verifier = _random(48);
      if (!await open(
        authUri(redirect: redirect, state: state, verifier: verifier),
      )) {
        throw const CalendarException('The browser couldn\'t be opened.');
      }
      String? code;
      await for (final req in server.timeout(
        wait,
        onTimeout: (sink) => sink.close(),
      )) {
        final q = req.uri.queryParameters;
        if (q['state'] != state) {
          // A stray request (a favicon, another program): not the answer.
          req.response.statusCode = 404;
          await req.response.close();
          continue;
        }
        final ok = q['code'] != null;
        req.response.headers.contentType = ContentType.html;
        req.response.write(_page(ok));
        await req.response.close();
        if (!ok) {
          throw CalendarException(
            q['error'] == 'access_denied'
                ? 'Google sign-in was cancelled.'
                : 'Google sign-in failed (${q['error'] ?? 'no answer'}).',
          );
        }
        code = q['code'];
        break;
      }
      if (code == null) {
        throw const CalendarException(
          'Google sign-in took too long. Try again.',
        );
      }
      return await _exchange(code, redirect, verifier);
    } finally {
      await server.close(force: true);
    }
  }

  static String _page(bool ok) =>
      '<!doctype html><meta charset="utf-8"><title>VoxCordis</title>'
      '<body style="font-family:sans-serif;background:#16141c;color:#eee;'
      'display:grid;place-items:center;height:90vh;text-align:center">'
      '<div><h2>${ok ? 'Connected' : 'Not connected'}</h2>'
      '<p>You can close this tab and go back to VoxCordis.</p></div>';

  Future<GoogleTokens> _exchange(
    String code,
    String redirect,
    String verifier,
  ) async {
    final json = await _post({
      'code': code,
      'client_id': client.id,
      if (client.secret.isNotEmpty) 'client_secret': client.secret,
      'redirect_uri': redirect,
      'grant_type': 'authorization_code',
      'code_verifier': verifier,
    });
    final refresh = '${json['refresh_token'] ?? ''}';
    if (refresh.isEmpty) {
      throw const CalendarException(
        'Google gave no lasting sign-in. Try again.',
      );
    }
    final tokens = _tokens(json, refresh);
    if (!tokens.scopes.contains(eventsScope)) {
      throw const CalendarException(
        'Google sign-in worked, but the calendar box wasn\'t ticked. Sign in '
        'again and allow VoxCordis to see and edit your events.',
      );
    }
    return tokens;
  }

  /// A fresh access token from [refresh].
  Future<GoogleTokens> refresh(String refresh) async {
    final json = await _post({
      'refresh_token': refresh,
      'client_id': client.id,
      if (client.secret.isNotEmpty) 'client_secret': client.secret,
      'grant_type': 'refresh_token',
    });
    return _tokens(json, '${json['refresh_token'] ?? refresh}');
  }

  /// Tells Google to forget this sign-in. Best effort.
  Future<void> revoke(String token) async {
    try {
      await _http
          .post(_revokeUrl, body: {'token': token})
          .timeout(const Duration(seconds: 15));
    } on Object {
      // Disconnecting still forgets the token here.
    }
  }

  GoogleTokens _tokens(Map<String, Object?> json, String refresh) =>
      GoogleTokens(
        refresh: refresh,
        access: '${json['access_token'] ?? ''}',
        expires: DateTime.now().add(
          Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
        ),
        scopes: '${json['scope'] ?? ''}'.split(' ').toSet(),
      );

  Future<Map<String, Object?>> _post(Map<String, String> body) async {
    final http.Response res;
    try {
      res = await _http
          .post(_tokenUrl, body: body)
          .timeout(const Duration(seconds: 30));
    } on Exception {
      throw const CalendarException('Google couldn\'t be reached.');
    }
    final json = _json(res.body);
    if (res.statusCode >= 300) {
      final error = '${json['error'] ?? res.statusCode}';
      throw CalendarException(
        error == 'invalid_grant'
            ? 'The Google sign-in ran out or was removed. Connect Google '
                  'Calendar again in Settings → Connections.'
            : 'Google refused the sign-in ($error).',
        signInAgain: error == 'invalid_grant',
      );
    }
    return json;
  }

  static Map<String, Object?> _json(String body) {
    try {
      final j = jsonDecode(body);
      return j is Map<String, Object?> ? j : {};
    } on FormatException {
      return {};
    }
  }
}

/// Google Calendar through its REST API, with the token from [GoogleAuth].
class GoogleSource implements CalendarSource {
  GoogleSource({
    required this.auth,
    required this.refreshToken,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final GoogleAuth auth;

  /// The lasting sign-in, from the secret store.
  final String refreshToken;
  final http.Client _http;

  GoogleTokens? _tokens;
  List<CalendarInfo>? _list;

  static const _api = 'https://www.googleapis.com/calendar/v3';

  @override
  bool get canWrite => true;

  Future<String> _access() async {
    final t = _tokens;
    if (t != null &&
        DateTime.now().isBefore(
          t.expires.subtract(const Duration(minutes: 1)),
        )) {
      return t.access;
    }
    return (_tokens = await auth.refresh(refreshToken)).access;
  }

  Future<http.Response> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('$_api$path').replace(queryParameters: query);
    for (var attempt = 0; ; attempt++) {
      final req = http.Request(method, uri)
        ..headers['Authorization'] = 'Bearer ${await _access()}';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json; charset=utf-8';
        req.body = jsonEncode(body);
      }
      final http.Response res;
      try {
        res = await http.Response.fromStream(
          await _http.send(req).timeout(const Duration(seconds: 30)),
        );
      } on Exception {
        throw const CalendarException('Google Calendar couldn\'t be reached.');
      }
      if (res.statusCode == 401 && attempt == 0) {
        _tokens = null;
        continue;
      }
      return res;
    }
  }

  static String _path(String id) => Uri.encodeComponent(id);

  Never _fail(http.Response res, String doing) {
    var message = '';
    try {
      message = '${((jsonDecode(res.body) as Map)['error'] as Map)['message']}';
    } on Object {
      // No message given.
    }
    throw CalendarException(
      'Google Calendar answered ${res.statusCode} $doing'
      '${message.isEmpty ? '' : ': $message'}.',
      signInAgain: res.statusCode == 401,
    );
  }

  @override
  Future<List<CalendarInfo>> calendars() async {
    if (_list case final list?) return list;
    final res = await _call(
      'GET',
      '/users/me/calendarList',
      query: {'minAccessRole': 'reader', 'maxResults': '250'},
    );
    if (res.statusCode == 403) {
      // Signed in without the list permission: the main calendar only.
      return _list = [
        const CalendarInfo(id: 'primary', name: 'Calendar', primary: true),
      ];
    }
    if (res.statusCode >= 300) _fail(res, 'listing the calendars');
    final items = (jsonDecode(res.body) as Map)['items'] as List? ?? [];
    return _list = [
      for (final i in items.cast<Map>())
        CalendarInfo(
          id: '${i['id']}',
          name: '${i['summaryOverride'] ?? i['summary'] ?? i['id']}',
          primary: i['primary'] == true,
          writable: i['accessRole'] == 'owner' || i['accessRole'] == 'writer',
        ),
    ];
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
      final res = await _call(
        'GET',
        '/calendars/${_path(c.id)}/events',
        query: {
          'timeMin': from.toUtc().toIso8601String(),
          'timeMax': to.toUtc().toIso8601String(),
          'singleEvents': 'true',
          'orderBy': 'startTime',
          'maxResults': '250',
        },
      );
      if (res.statusCode == 404) continue;
      if (res.statusCode >= 300) _fail(res, 'listing events');
      final items = (jsonDecode(res.body) as Map)['items'] as List? ?? [];
      for (final i in items.cast<Map>()) {
        if (i['status'] == 'cancelled') continue;
        if (fromJson(i, c) case final e?) out.add(e);
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// An event as the API gives it.
  static CalendarEvent? fromJson(Map json, CalendarInfo c) {
    ({DateTime at, bool day})? time(Object? t) {
      if (t is! Map) return null;
      if (t['dateTime'] case final String s) {
        final at = DateTime.tryParse(s);
        return at == null ? null : (at: at.toLocal(), day: false);
      }
      if (t['date'] case final String s) {
        final at = DateTime.tryParse(s);
        return at == null
            ? null
            : (at: DateTime(at.year, at.month, at.day), day: true);
      }
      return null;
    }

    final start = time(json['start']);
    final end = time(json['end']);
    if (start == null) return null;
    return CalendarEvent(
      id: '${json['id']}',
      title: '${json['summary'] ?? '(no title)'}',
      start: start.at,
      end: end?.at ?? start.at,
      allDay: start.day,
      location: '${json['location'] ?? ''}',
      notes: '${json['description'] ?? ''}',
      calendarId: c.id,
      calendarName: c.name,
      repeats: json['recurringEventId'] != null,
      etag: json['etag'] as String?,
    );
  }

  static Map<String, Object?> toJson(CalendarEvent e) {
    Map<String, Object?> time(DateTime t) => e.allDay
        ? {
            'date':
                '${t.year.toString().padLeft(4, '0')}-'
                '${t.month.toString().padLeft(2, '0')}-'
                '${t.day.toString().padLeft(2, '0')}',
          }
        : {'dateTime': t.toUtc().toIso8601String()};
    return {
      'summary': e.title,
      'location': e.location,
      'description': e.notes,
      'start': time(e.start),
      'end': time(e.end),
    };
  }

  @override
  Future<CalendarEvent> add(CalendarEvent event, {String? calendarId}) async {
    final all = await calendars();
    final c =
        all.where((c) => c.id == calendarId).firstOrNull ??
        all.firstWhere((c) => c.primary, orElse: () => all.first);
    final res = await _call(
      'POST',
      '/calendars/${_path(c.id)}/events',
      body: toJson(event),
    );
    if (res.statusCode >= 300) _fail(res, 'adding the event');
    return fromJson(jsonDecode(res.body) as Map, c) ?? event;
  }

  @override
  Future<CalendarEvent> update(CalendarEvent event) async {
    final c =
        (await calendars())
            .where((c) => c.id == event.calendarId)
            .firstOrNull ??
        CalendarInfo(id: event.calendarId, name: event.calendarName);
    final res = await _call(
      'PATCH',
      '/calendars/${_path(c.id)}/events/${_path(event.id)}',
      body: toJson(event),
    );
    if (res.statusCode >= 300) _fail(res, 'changing the event');
    return fromJson(jsonDecode(res.body) as Map, c) ?? event;
  }

  @override
  Future<void> delete(CalendarEvent event) async {
    final res = await _call(
      'DELETE',
      '/calendars/${_path(event.calendarId)}/events/${_path(event.id)}',
    );
    if (res.statusCode >= 300 && res.statusCode != 410) {
      _fail(res, 'deleting the event');
    }
  }
}
