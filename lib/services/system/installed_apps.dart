import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../folder_service.dart';

/// A program the human has installed, as their system's app menu lists it.
class InstalledApp {
  const InstalledApp({
    required this.name,
    required this.id,
    this.path,
    this.exec,
  });

  /// The name people see in the menu ("Vivaldi", "Google Chrome").
  final String name;

  /// Linux: the desktop file id ("vivaldi-stable.desktop"). Windows: the
  /// Start menu AppID. macOS: the bundle's name.
  final String id;

  /// The desktop file, shortcut or bundle it was found as, if any.
  final String? path;

  /// Linux: the desktop file's Exec line, used when no launcher helps.
  final String? exec;

  @override
  String toString() => '$name ($id)';
}

/// The apps the human could start from their menu, found by name: Linux
/// desktop files, the Windows Start menu, macOS Applications. Read once a
/// minute at most.
class InstalledApps {
  InstalledApps({Future<List<InstalledApp>> Function()? list})
    : _list = list ?? _scan;

  final Future<List<InstalledApp>> Function() _list;
  List<InstalledApp>? _apps;
  DateTime? _read;

  Future<List<InstalledApp>> all() async {
    final now = DateTime.now();
    if (_apps == null ||
        _read == null ||
        now.difference(_read!) > const Duration(minutes: 1)) {
      try {
        _apps = await _list();
      } catch (_) {
        _apps = const [];
      }
      _read = now;
    }
    return _apps!;
  }

  /// The app [name] means, as people say it: "vivaldi", "Chrome", "files".
  /// With [strict], only a whole name or a whole run of its words counts,
  /// for guessing from everyday words; otherwise the start of a name does
  /// too. Null when nothing fits.
  Future<InstalledApp?> find(String name, {bool strict = false}) async =>
      best(await all(), name, strict: strict);

  static InstalledApp? best(
    List<InstalledApp> apps,
    String name, {
    bool strict = false,
  }) {
    final q = _words(name);
    if (q.isEmpty || q.join().length < 3) return null;
    int? rank(InstalledApp a) {
      final n = _words(a.name);
      if (_same(n, q)) return 0;
      final id = _words(_idName(a.id));
      if (_same(id, q)) return 1;
      if (_contains(n, q)) return 2;
      if (_contains(id, q)) return 3;
      if (strict) return null;
      // A start only from four letters: "vival", not "vi".
      if (q.join().length >= 4 && n.join(' ').startsWith(q.join(' '))) {
        return 4;
      }
      return null;
    }

    InstalledApp? found;
    int? foundRank;
    for (final a in apps) {
      final r = rank(a);
      if (r == null) continue;
      if (foundRank == null ||
          r < foundRank ||
          (r == foundRank && a.name.length < found!.name.length)) {
        found = a;
        foundRank = r;
      }
    }
    return found;
  }

  static List<String> _words(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();

  static bool _same(List<String> a, List<String> b) =>
      a.length == b.length && a.join(' ') == b.join(' ');

  static bool _contains(List<String> words, List<String> run) {
    for (var i = 0; i + run.length <= words.length; i++) {
      if (_same(words.sublist(i, i + run.length), run)) return true;
    }
    return false;
  }

  /// "com.vivaldi.Vivaldi.desktop" → "Vivaldi", "vivaldi-stable.desktop" →
  /// "vivaldi stable", "Microsoft.WindowsCalculator_8wekyb!App" → "WindowsCalculator".
  static String _idName(String id) {
    var s = id.replaceFirst(RegExp(r'\.desktop$'), '');
    s = s.split('!').first.split('_').first;
    s = s.split(RegExp(r'[\\/]')).last;
    if (s.contains('.')) s = s.split('.').last;
    return s;
  }

  /// Starts [app] apart from VoxCordis, so it stays open after we close.
  static Future<void> launch(InstalledApp app) async {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        'shell:AppsFolder\\${app.id}',
      ], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [
        '-a',
        app.path ?? app.name,
      ], mode: ProcessStartMode.detached);
      return;
    }
    final env = _cleanEnv();
    final id = app.id.replaceFirst(RegExp(r'\.desktop$'), '');
    for (final (cmd, args) in [
      ('gtk-launch', [id]),
      if (app.path != null) ('gio', ['launch', app.path!]),
    ]) {
      try {
        final r = await Process.run(
          cmd,
          args,
          environment: env,
          includeParentEnvironment: false,
        );
        if (r.exitCode == 0) return;
      } catch (_) {
        // Not installed: the next way.
      }
    }
    final argv = execArgs(app.exec ?? '');
    if (argv.isEmpty) throw 'Can\'t tell how to start ${app.name}';
    await Process.start(
      argv.first,
      argv.skip(1).toList(),
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: homeDir,
      mode: ProcessStartMode.detached,
    );
  }

  /// Our environment without what the AppImage runtime adds for us.
  static Map<String, String> _cleanEnv() => {
    for (final e in Platform.environment.entries)
      if (!const {'APPDIR', 'APPIMAGE', 'ARGV0', 'OWD'}.contains(e.key))
        e.key: e.value,
  };

  /// A desktop file's Exec line as arguments, with its %f, %U… left out.
  static List<String> execArgs(String exec) {
    final args = <String>[];
    final cur = StringBuffer();
    var quoted = false, any = false;
    for (var i = 0; i < exec.length; i++) {
      final c = exec[i];
      if (quoted && c == '\\' && i + 1 < exec.length) {
        cur.write(exec[++i]);
      } else if (c == '"') {
        quoted = !quoted;
        any = true;
      } else if (!quoted && (c == ' ' || c == '\t')) {
        if (cur.isNotEmpty || any) args.add(cur.toString());
        cur.clear();
        any = false;
      } else {
        cur.write(c);
      }
    }
    if (cur.isNotEmpty || any) args.add(cur.toString());
    return [
      for (final a in args)
        if (!RegExp(r'^%[a-zA-Z]$').hasMatch(a)) a.replaceAll('%%', '%'),
    ];
  }

  static Future<List<InstalledApp>> _scan() async {
    if (Platform.isWindows) return _windows();
    if (Platform.isMacOS) return _mac();
    return _linux();
  }

  static Future<List<InstalledApp>> _linux() async {
    final env = Platform.environment;
    final dataHome = env['XDG_DATA_HOME'] ?? p.join(homeDir, '.local/share');
    final dataDirs = (env['XDG_DATA_DIRS']?.isNotEmpty ?? false)
        ? env['XDG_DATA_DIRS']!.split(':')
        : ['/usr/local/share', '/usr/share'];
    final dirs = {
      dataHome,
      ...dataDirs,
      p.join(homeDir, '.local/share/flatpak/exports/share'),
      '/var/lib/flatpak/exports/share',
      '/var/lib/snapd/desktop',
    };
    final byId = <String, InstalledApp?>{};
    for (final d in dirs) {
      final apps = Directory(p.join(d, 'applications'));
      if (!apps.existsSync()) continue;
      await for (final f in apps.list(recursive: true, followLinks: true)) {
        if (f is! File || !f.path.endsWith('.desktop')) continue;
        // The first directory wins, as the menu does it.
        final id = p
            .relative(f.path, from: apps.path)
            .replaceAll(p.separator, '-');
        if (byId.containsKey(id)) continue;
        byId[id] = parseDesktopFile(id, f.path, await _readOr(f));
      }
    }
    return byId.values.whereType<InstalledApp>().toList();
  }

  static Future<String> _readOr(File f) async {
    try {
      return await f.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// One desktop file as an app, or null for one the menu hides.
  static InstalledApp? parseDesktopFile(String id, String path, String text) {
    String? name, exec;
    var section = '', hidden = false, isApp = false;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        section = line;
        continue;
      }
      if (section != '[Desktop Entry]') continue;
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      final key = line.substring(0, eq).trim();
      final value = line.substring(eq + 1).trim();
      switch (key) {
        case 'Name':
          name = value;
        case 'Exec':
          exec = value;
        case 'Type':
          isApp = value == 'Application';
        case 'NoDisplay' || 'Hidden':
          hidden = hidden || value == 'true';
      }
    }
    if (!isApp || hidden || name == null || exec == null) return null;
    return InstalledApp(name: name, id: id, path: path, exec: exec);
  }

  static Future<List<InstalledApp>> _windows() async {
    // Get-StartApps lists Start menu apps, Store apps included, with the
    // AppID that shell:AppsFolder starts.
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
          'Get-StartApps | Select-Object Name, AppID | ConvertTo-Json -Compress',
    ], stdoutEncoding: utf8);
    final out = (r.stdout as String).trim();
    if (out.isEmpty) return const [];
    final json = jsonDecode(out);
    return [
      for (final e in json is List ? json : [json])
        if (e is Map && e['Name'] is String && e['AppID'] is String)
          InstalledApp(name: e['Name'] as String, id: e['AppID'] as String),
    ];
  }

  static Future<List<InstalledApp>> _mac() async {
    final found = <InstalledApp>[];
    for (final d in [
      '/Applications',
      '/Applications/Utilities',
      '/System/Applications',
      '/System/Applications/Utilities',
      p.join(homeDir, 'Applications'),
    ]) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e.path.endsWith('.app')) {
          final name = p.basenameWithoutExtension(e.path);
          found.add(InstalledApp(name: name, id: name, path: e.path));
        }
      }
    }
    return found;
  }
}
