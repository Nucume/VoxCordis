import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/calendar/calendar_event.dart';
import '../../services/calendar/calendar_tools.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import 'model_picker.dart' show InfoIcon;
import 'settings_text.dart';

/// Settings → Connections: the outside services the companion can use.
/// For now the human's calendar: Google (signed in through the browser),
/// any CalDAV server, or a read-only private link.
///
/// Connecting and the choices here are saved at once, like the encryption
/// key, since they come with a sign-in that can't wait for Save.
class ConnectionsSettings extends StatefulWidget {
  const ConnectionsSettings({super.key});

  @override
  State<ConnectionsSettings> createState() => _ConnectionsSettingsState();
}

class _ConnectionsSettingsState extends State<ConnectionsSettings> {
  CalendarProvider _pick = CalendarProvider.google;
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _link = TextEditingController();

  bool _busy = false;
  String? _error;
  bool? _hasGoogleClient;
  bool _ownGoogleClient = false;

  /// The connected source's calendars, null while loading.
  List<CalendarInfo>? _calendars;
  String? _listError;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final c = AppScope.of(context).settings.value.calendar;
    _url.text = c.caldavUrl;
    _user.text = c.caldavUser;
    _checkGoogleClient();
    if (c.connected) _loadCalendars();
  }

  @override
  void dispose() {
    for (final c in [_url, _user, _password, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _checkGoogleClient() async {
    final calendar = AppScope.of(context).calendar;
    final has = await calendar.googleClient() != null;
    final own = await calendar.ownGoogleClient();
    if (mounted) {
      setState(() {
        _hasGoogleClient = has;
        _ownGoogleClient = own;
      });
    }
  }

  Future<void> _loadCalendars() async {
    setState(() {
      _calendars = null;
      _listError = null;
    });
    try {
      final list = await AppScope.of(context).calendar.calendars();
      if (mounted) setState(() => _calendars = list);
    } catch (e) {
      if (mounted) {
        setState(() {
          _calendars = const [];
          _listError = '$e';
        });
      }
    }
  }

  Future<void> _save(CalendarPrefs c) async {
    final store = AppScope.of(context).settings;
    await store.update(store.value.copyWith(calendar: c));
  }

  /// Runs a connect, saving what it returns and showing what it found.
  Future<void> _connect(
    Future<({CalendarPrefs prefs, List<CalendarInfo> calendars})> Function()
    run,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await run();
      await _save(r.prefs);
      _password.clear();
      _link.clear();
      if (mounted) {
        setState(() {
          _calendars = r.calendars;
          _listError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final name = AppScope.of(context).settings.value.companionName;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_off_rounded),
        title: const Text('Disconnect the calendar?'),
        content: SizedBox(
          width: 380,
          child: Text(
            '$name won\'t see or change your calendar any more. Your events '
            'stay as they are.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _save(await AppScope.of(context).calendar.disconnect());
      if (mounted) setState(() => _calendars = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadClientFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Google client', extensions: ['json']),
      ],
    );
    if (file == null || !mounted) return;
    final ok = await AppScope.of(
      context,
    ).calendar.setGoogleClient(await file.readAsString());
    if (!mounted) return;
    setState(
      () => _error = ok
          ? null
          : 'That isn\'t a Google client file. Download the JSON of a '
                '"Desktop app" client from Google Cloud.',
    );
    await _checkGoogleClient();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final s = services.settings.value;
        final c = s.calendar;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection('Calendar'),
            SettingsNote(
              'Let ${s.companionName} see what you have on and, if you '
              'like, add, move and delete events for you. Everything stays '
              'between this computer and your calendar provider.',
            ),
            const SizedBox(height: 12),
            if (c.connected) ..._connected(s) else ..._connectForm(s),
            if (_error case final e?)
              SettingsNote(e, color: Theme.of(context).colorScheme.error),
          ],
        );
      },
    );
  }

  List<Widget> _connected(AppSettings s) {
    final c = s.calendar;
    final palette = context.palette;
    final (icon, what) = switch (c.provider) {
      CalendarProvider.google => (Icons.event_rounded, 'Google Calendar'),
      CalendarProvider.caldav => (Icons.dns_rounded, 'CalDAV'),
      _ => (Icons.link_rounded, 'Calendar link (read-only)'),
    };
    final calendars = _calendars;
    final writable = [
      for (final cal in calendars ?? const <CalendarInfo>[])
        if (cal.writable) cal,
    ];
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: palette.tile,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected: $what',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (c.account.isNotEmpty)
                    Text(
                      c.account,
                      style: TextStyle(fontSize: 12, color: palette.textMuted),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(Icons.link_off_rounded, size: 18),
              label: const Text('Disconnect'),
            ),
          ],
        ),
      ),
      if (!CalendarTools.brainMayRead(s)) ...[
        const SizedBox(height: 8),
        SettingsNote(
          CalendarTools.brainBlocked,
          color: Theme.of(context).colorScheme.error,
        ),
      ] else if (CalendarTools.noTrainingRouting(s)) ...[
        const SizedBox(height: 8),
        const SettingsNote(
          'With OpenRouter, VoxCordis asks only for providers that don\'t '
          'keep or train on what they\'re sent, as Google requires. A few '
          'models may not be offered that way.',
        ),
      ],
      if (c.canWrite)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: c.askFirst,
          onChanged: (on) => _save(c.copyWith(askFirst: on)),
          title: Text(
            'Ask me before ${s.companionName} adds, moves or deletes an '
            'event',
          ),
          subtitle: SettingsNote(
            c.askFirst
                ? 'You see each change and say yes or no.'
                : 'Changes happen at once. After reading the web, and in '
                      'automations, ${s.companionName} still asks or '
                      'leaves it.',
          ),
        ),
      SettingsSection('Calendars'),
      if (calendars == null)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator()),
        )
      else ...[
        if (_listError case final e?) ...[
          SettingsNote(e, color: Theme.of(context).colorScheme.error),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _loadCalendars,
              child: const Text('Try again'),
            ),
          ),
        ],
        if (calendars.length > 1) ...[
          SettingsNote('${s.companionName} reads the ticked ones.'),
          for (final cal in calendars)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: c.calendars.isEmpty || c.calendars.contains(cal.id),
              title: Text(cal.name),
              subtitle: cal.writable || !c.canWrite
                  ? null
                  : SettingsNote('Read-only'),
              onChanged: (on) {
                final ticked = c.calendars.isEmpty
                    ? [for (final x in calendars) x.id]
                    : [...c.calendars];
                if (on == true) {
                  ticked.add(cal.id);
                } else {
                  ticked.remove(cal.id);
                }
                // Every one ticked is saved as "all", so new ones count.
                final all = calendars.every((x) => ticked.contains(x.id));
                _save(c.copyWith(calendars: all ? const [] : ticked));
              },
            ),
        ] else if (calendars.isNotEmpty)
          SettingsNote('Reading "${calendars.first.name}".'),
        if (c.canWrite && writable.length > 1) ...[
          const SizedBox(height: 12),
          GlassSelect<String>(
            label: 'New events go to',
            value:
                writable.where((w) => w.id == c.writeTo).firstOrNull?.id ??
                writable
                    .firstWhere((w) => w.primary, orElse: () => writable.first)
                    .id,
            options: [for (final w in writable) GlassOption(w.id, w.name)],
            onChanged: (id) => _save(c.copyWith(writeTo: id)),
          ),
        ],
      ],
    ];
  }

  List<Widget> _connectForm(AppSettings s) {
    return [
      Row(
        children: [
          Expanded(
            child: GlassSelect<CalendarProvider>(
              label: 'Connect with',
              value: _pick,
              options: const [
                GlassOption(
                  CalendarProvider.google,
                  'Google Calendar (sign in in your browser)',
                ),
                GlassOption(
                  CalendarProvider.caldav,
                  'CalDAV: iCloud, Fastmail, Nextcloud and others',
                ),
                GlassOption(
                  CalendarProvider.link,
                  'A private calendar link (read-only)',
                ),
              ],
              onChanged: (v) => setState(() {
                _pick = v;
                _error = null;
              }),
            ),
          ),
          const SizedBox(width: 8),
          const InfoIcon(
            message:
                'Google and CalDAV let your companion read and change '
                'events. A private link (.ics) works with any calendar but '
                'only lets it read. Passwords and sign-ins are kept in your '
                'keyring, never in a file.',
          ),
        ],
      ),
      const SizedBox(height: 12),
      ...switch (_pick) {
        CalendarProvider.caldav => _caldavForm(),
        CalendarProvider.link => _linkForm(),
        _ => _googleForm(s),
      },
    ];
  }

  Widget _button(String label, IconData icon, VoidCallback? onPressed) => Align(
    alignment: Alignment.centerLeft,
    child: FilledButton.icon(
      onPressed: _busy ? null : onPressed,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 18),
      label: Text(label),
    ),
  );

  List<Widget> _googleForm(AppSettings s) {
    final services = AppScope.of(context);
    final has = _hasGoogleClient;
    return [
      if (has == false)
        SettingsNote(
          'This copy of VoxCordis has no Google sign-in built in yet. You '
          'can use your own: in Google Cloud, make a "Desktop app" client '
          'with the Calendar API on, download its JSON and load it here.',
        )
      else ...[
        _button(
          'Sign in with Google',
          Icons.login_rounded,
          () => _connect(
            () => services.calendar.connectGoogle(
              (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
            ),
          ),
        ),
        SettingsNote(
          _busy
              ? 'Finish signing in in your browser, then come back here.'
              : 'Your browser opens Google\'s page. Google may say the app '
                    'isn\'t verified yet: choose Advanced, then Go to '
                    'VoxCordis. Only calendar access is asked for.',
        ),
      ],
      Wrap(
        spacing: 4,
        children: [
          TextButton(
            onPressed: _busy ? null : _loadClientFile,
            child: Text(
              _ownGoogleClient
                  ? 'Use another Google client file…'
                  : 'Use your own Google client file…',
            ),
          ),
          if (_ownGoogleClient)
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await services.calendar.clearGoogleClient();
                      await _checkGoogleClient();
                    },
              child: const Text('Use the built-in one again'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _caldavForm() {
    final services = AppScope.of(context);
    return [
      TextField(
        controller: _url,
        decoration: const InputDecoration(
          labelText: 'Server address',
          hintText: 'caldav.icloud.com',
          helperText:
              'iCloud: caldav.icloud.com · Fastmail: caldav.fastmail.com · '
              'Nextcloud: your-server/remote.php/dav',
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _user,
        decoration: const InputDecoration(labelText: 'User name or email'),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'App password',
          helperText:
              'Make one in your account\'s security settings (for iCloud at '
              'account.apple.com). Kept in your keyring.',
        ),
      ),
      const SizedBox(height: 12),
      _button(
        'Connect',
        Icons.link_rounded,
        () => _connect(
          () => services.calendar.connectCalDav(
            url: _url.text,
            user: _user.text.trim(),
            password: _password.text,
          ),
        ),
      ),
    ];
  }

  List<Widget> _linkForm() {
    final services = AppScope.of(context);
    return [
      TextField(
        controller: _link,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Private calendar address (.ics)',
          helperText:
              'Google: Settings → your calendar → "Secret address in iCal '
              'format". Outlook: Settings → Shared calendars → Publish. '
              'Anyone with this link can read the calendar, so it\'s kept '
              'in your keyring.',
          helperMaxLines: 3,
        ),
      ),
      const SizedBox(height: 12),
      _button(
        'Connect',
        Icons.link_rounded,
        () => _connect(() => services.calendar.connectLink(_link.text)),
      ),
    ];
  }
}
