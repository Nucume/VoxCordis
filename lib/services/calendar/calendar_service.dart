import 'package:http/http.dart' as http;

import '../../data/settings.dart';
import '../secret_store.dart';
import 'caldav.dart';
import 'calendar_event.dart';
import 'google_calendar.dart';
import 'link_source.dart';

/// The calendar connected in Settings → Connections: builds the right
/// [CalendarSource] from the settings and the secrets, and does the
/// connecting and disconnecting.
class CalendarService {
  CalendarService({
    required this.settings,
    SecretStore? secrets,
    http.Client? client,
  }) : _secrets = secrets,
       _http = client;

  final AppSettings Function() settings;
  final SecretStore? _secrets;
  final http.Client? _http;

  /// Kept here when there is no secret store (tests).
  final _memory = <String, String>{};

  static const googleTokenSecret = 'calendar-google-token';
  static const googleClientSecret = 'calendar-google-client';
  static const caldavPasswordSecret = 'calendar-caldav-password';
  static const linkSecret = 'calendar-link';

  CalendarSource? _source;
  String? _sourceFor;

  Future<String?> _read(String name) async {
    final s = _secrets;
    final v = s == null ? _memory[name] : await s.read(name);
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> _write(String name, String value) async {
    final s = _secrets;
    if (s == null) {
      _memory[name] = value;
    } else {
      await s.write(name, value);
    }
  }

  Future<void> _delete(String name) async {
    final s = _secrets;
    if (s == null) {
      _memory.remove(name);
    } else {
      await s.delete(name);
    }
  }

  /// The Google client: one the human loaded themselves, else the one
  /// built in.
  Future<GoogleClient?> googleClient() async {
    final saved = await _read(googleClientSecret);
    final own = saved == null ? null : GoogleClient.fromJson(saved);
    return own ?? GoogleClient.builtIn;
  }

  /// Whether the human loaded a Google client of their own.
  Future<bool> ownGoogleClient() async =>
      await _read(googleClientSecret) != null;

  /// Goes back to the built-in Google client.
  Future<void> clearGoogleClient() => _delete(googleClientSecret);

  /// Keeps the client file the human picked; false when it isn't one.
  Future<bool> setGoogleClient(String json) async {
    final c = GoogleClient.fromJson(json);
    if (c == null) return false;
    await _write(googleClientSecret, c.toJson());
    return true;
  }

  /// The connected calendar, or null when none is.
  Future<CalendarSource?> source() async {
    final c = settings().calendar;
    final key = '${c.provider.name}|${c.caldavUrl}|${c.caldavUser}';
    if (_source != null && _sourceFor == key) return _source;
    final CalendarSource? next = switch (c.provider) {
      CalendarProvider.none => null,
      CalendarProvider.google => await _google(),
      CalendarProvider.caldav => await _caldav(c),
      CalendarProvider.link => await _link(),
    };
    _source = next;
    _sourceFor = key;
    return next;
  }

  /// Forgets the built source, so the next [source] signs in afresh.
  void reset() {
    _source = null;
    _sourceFor = null;
  }

  Future<CalendarSource?> _google() async {
    final client = await googleClient();
    final token = await _read(googleTokenSecret);
    if (client == null || token == null) return null;
    return GoogleSource(
      auth: GoogleAuth(client, http: _http),
      refreshToken: token,
      client: _http,
    );
  }

  Future<CalendarSource?> _caldav(CalendarPrefs c) async {
    final password = await _read(caldavPasswordSecret);
    if (password == null || c.caldavUrl.isEmpty) return null;
    return CalDavSource(
      url: c.caldavUrl,
      user: c.caldavUser,
      password: password,
      client: _http,
    );
  }

  Future<CalendarSource?> _link() async {
    final link = await _read(linkSecret);
    return link == null ? null : LinkSource(link, client: _http);
  }

  /// Signs in to Google in the browser ([open]) and returns the settings to
  /// save, with the calendars found.
  Future<({CalendarPrefs prefs, List<CalendarInfo> calendars})> connectGoogle(
    Future<bool> Function(Uri) open,
  ) async {
    final client = await googleClient();
    if (client == null) {
      throw const CalendarException(
        'This copy of VoxCordis has no Google sign-in built in. Load a '
        'client file under "Your own Google client".',
      );
    }
    final auth = GoogleAuth(client, http: _http);
    final tokens = await auth.signIn(open);
    final source = GoogleSource(
      auth: auth,
      refreshToken: tokens.refresh,
      client: _http,
    );
    final calendars = await source.calendars();
    await _forgetOthers();
    await _write(googleTokenSecret, tokens.refresh);
    final main = calendars.where((c) => c.primary).firstOrNull;
    reset();
    return (
      prefs: settings().calendar.copyWith(
        provider: CalendarProvider.google,
        // The main calendar's id is the account's address.
        account: main != null && main.id.contains('@') ? main.id : '',
        calendars: const [],
        clearWriteTo: true,
      ),
      calendars: calendars,
    );
  }

  /// Checks the CalDAV account and returns the settings to save.
  Future<({CalendarPrefs prefs, List<CalendarInfo> calendars})> connectCalDav({
    required String url,
    required String user,
    required String password,
  }) async {
    final source = CalDavSource(
      url: url,
      user: user,
      password: password,
      client: _http,
    );
    final calendars = await source.calendars();
    await _forgetOthers();
    await _write(caldavPasswordSecret, password);
    reset();
    return (
      prefs: settings().calendar.copyWith(
        provider: CalendarProvider.caldav,
        account: user,
        caldavUrl: CalDavSource.normalise(url).toString(),
        caldavUser: user,
        calendars: const [],
        clearWriteTo: true,
      ),
      calendars: calendars,
    );
  }

  /// Checks the private link and returns the settings to save.
  Future<({CalendarPrefs prefs, List<CalendarInfo> calendars})> connectLink(
    String link,
  ) async {
    final source = LinkSource(link, client: _http);
    final calendars = await source.calendars();
    await _forgetOthers();
    await _write(linkSecret, link.trim());
    reset();
    return (
      prefs: settings().calendar.copyWith(
        provider: CalendarProvider.link,
        account: calendars.first.name,
        calendars: const [],
        clearWriteTo: true,
      ),
      calendars: calendars,
    );
  }

  /// The calendars of the connected source, for Settings.
  Future<List<CalendarInfo>> calendars() async =>
      await (await source())?.calendars() ?? const [];

  /// Forgets every calendar secret, telling Google to drop its sign-in,
  /// and returns the settings to save.
  Future<CalendarPrefs> disconnect() async {
    await _forgetOthers();
    reset();
    return CalendarPrefs(askFirst: settings().calendar.askFirst);
  }

  Future<void> _forgetOthers() async {
    final token = await _read(googleTokenSecret);
    final client = await googleClient();
    if (token != null && client != null) {
      await GoogleAuth(client, http: _http).revoke(token);
    }
    for (final name in [googleTokenSecret, caldavPasswordSecret, linkSecret]) {
      await _delete(name);
    }
  }
}
