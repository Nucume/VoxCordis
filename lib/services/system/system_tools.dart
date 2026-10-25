import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../data/settings.dart';
import '../folder_service.dart';
import 'installed_apps.dart';

/// What the companion wants to do outside its folder.
class SystemRequest {
  const SystemRequest({
    required this.tool,
    required this.target,
    this.why = '',
    this.runnable = false,
  });

  /// `run_command` or `open`.
  final String tool;

  /// The command line, or the address, file or folder to open.
  final String target;

  /// The companion's reason, in its own words.
  final String why;

  /// For `open`: the target is a program or script, which runs as the
  /// human. Such a request is asked about every time.
  final bool runnable;

  /// How the request is kept in the always-allowed list: exact, so allowing
  /// `ls` never allows `ls; rm -rf ~`.
  String get key => '${tool == runTool ? 'run' : 'open'}: $target';

  static const runTool = 'run_command';
  static const openTool = 'open';
}

enum SystemApproval { deny, once, always }

/// Tools that reach the human's computer beyond the companion folder: run a
/// command, open an address, file or folder. They are offered only while
/// system access is on in Settings, every use is asked about first unless
/// the human allowed that exact one always, and every use is logged.
class SystemTools {
  SystemTools({
    required this.settings,
    required this.logFile,
    required this.allowAlways,
    this.timeout = const Duration(minutes: 2),
    this.launcher = _launch,
    this.knownFolder = userFolder,
    InstalledApps? apps,
    this.startApp = InstalledApps.launch,
  }) : apps = apps ?? InstalledApps();

  final AppSettings Function() settings;
  final File logFile;

  /// Adds a request's key to the always-allowed list in Settings.
  final Future<void> Function(String key) allowAlways;

  /// Shows the human what the companion wants to do and waits for the
  /// answer. Set by the window; with nothing set every request is denied.
  Future<SystemApproval> Function(SystemRequest request)? ask;

  final Duration timeout;

  /// Opens a URI with the system's default app; replaced in tests.
  final Future<bool> Function(Uri uri) launcher;

  /// Finds the human's Pictures, Documents… folder; replaced in tests.
  final Future<String?> Function(String name) knownFolder;

  /// The human's installed apps, which `open` also starts by name;
  /// replaced in tests.
  InstalledApps apps;

  /// Starts an installed app; replaced in tests.
  final Future<void> Function(InstalledApp app) startApp;

  static const names = {SystemRequest.runTool, SystemRequest.openTool};

  /// Files that run something when opened, rather than show it.
  static const runnableExtensions = {
    '.exe',
    '.bat',
    '.cmd',
    '.com',
    '.ps1',
    '.psm1',
    '.vbs',
    '.vbe',
    '.js',
    '.jse',
    '.wsf',
    '.wsh',
    '.hta',
    '.msi',
    '.msp',
    '.lnk',
    '.url',
    '.scr',
    '.pif',
    '.cpl',
    '.msc',
    '.reg',
    '.jar',
    '.appref-ms',
    '.application',
    '.settingcontent-ms',
    '.library-ms',
    '.sh',
    '.bash',
    '.zsh',
    '.run',
    '.bin',
    '.desktop',
    '.appimage',
    '.app',
    '.command',
    '.py',
    '.pyw',
    '.pl',
    '.rb',
    '.deb',
    '.rpm',
    '.flatpakref',
    '.pkg',
    '.dmg',
  };

  /// Whether opening [path] would run something: by its extension, as the
  /// OS reads it (Windows drops trailing dots and spaces), or, outside
  /// Windows, an existing file marked executable.
  static bool isRunnable(String path) {
    final uri = Uri.tryParse(path);
    if (uri != null &&
        const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
      return false; // example.com is a website, not a .com program.
    }
    final name = p.basename(path).replaceFirst(RegExp(r'[. ]+$'), '');
    if (runnableExtensions.contains(p.extension(name).toLowerCase())) {
      return true;
    }
    if (Platform.isWindows) return false;
    try {
      final stat = FileStat.statSync(path);
      return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
    } on Object {
      return false;
    }
  }

  /// What a command's output may add to the prompt.
  static const maxOutput = 8000;

  static String get shellName => Platform.isWindows ? 'PowerShell' : 'sh';

  static List<Map<String, Object?>> get definitions => [
    {
      'type': 'function',
      'function': {
        'name': SystemRequest.runTool,
        'description':
            'Run a command on your human\'s computer ($shellName, starting '
            'in your folder) and get its output. Your human sees the exact '
            'command and approves it first. One clear command at a time; '
            'never hide what it does.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The command line, exactly as it should run.',
            },
            'why': {
              'type': 'string',
              'description': 'Why, in a few words, shown to your human.',
            },
          },
          'required': ['command', 'why'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': SystemRequest.openTool,
        'description':
            'Open an app, a web address, a file or a folder on your human\'s '
            'computer. An installed app starts by its name (Vivaldi, Steam, '
            'Spotify…). A folder opens in their file manager (File Explorer, '
            'Finder…); their usual folders work by name: Pictures, '
            'Documents, Downloads, Desktop, Music, Videos, Home. Other paths '
            'may be relative to your folder, start with ~, or be absolute. '
            'Your human approves it first.',
        'parameters': {
          'type': 'object',
          'properties': {
            'target': {
              'type': 'string',
              'description':
                  'e.g. Vivaldi, https://example.com, Pictures, '
                  '~/Downloads/a.pdf, notes/today.md',
            },
            'why': {
              'type': 'string',
              'description': 'Why, in a few words, shown to your human.',
            },
          },
          'required': ['target', 'why'],
        },
      },
    },
  ];

  /// Runs one tool call and returns the JSON string sent back to the model.
  Future<String> call(String name, Map<String, Object?> args) async {
    final s = settings();
    final target =
        ((name == SystemRequest.runTool ? args['command'] : args['target'])
                    as String? ??
                '')
            .trim();
    var request = SystemRequest(
      tool: name,
      target: target,
      why: (args['why'] as String? ?? '').trim(),
    );
    try {
      if (!s.systemAccess) {
        throw 'System access is off. Your human can turn it on in Settings.';
      }
      if (!names.contains(name)) throw 'unknown tool $name';
      if (request.target.isEmpty) {
        throw name == SystemRequest.runTool
            ? '"command" is empty'
            : '"target" is empty';
      }
      if (name == SystemRequest.openTool) {
        request = SystemRequest(
          tool: name,
          target: target,
          why: request.why,
          runnable: await _opensRunnable(target, s),
        );
      }
      final approval =
          !request.runnable && s.allowedSystemActions.contains(request.key)
          ? SystemApproval.always
          : await (ask?.call(request) ?? Future.value(SystemApproval.deny));
      if (approval == SystemApproval.deny) {
        await _log(request, 'denied');
        return jsonEncode({
          'ok': false,
          'error': 'Your human said no. Don\'t try another way around it.',
        });
      }
      if (approval == SystemApproval.always &&
          !request.runnable &&
          !s.allowedSystemActions.contains(request.key)) {
        await allowAlways(request.key);
      }
      return name == SystemRequest.runTool
          ? await _run(request, s)
          : await _open(request, s);
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  /// Whether [target], found the way `open` finds it, is a program or
  /// script.
  Future<bool> _opensRunnable(String target, AppSettings s) async {
    try {
      final uri = await resolveTarget(
        target,
        s.companionFolder,
        knownFolder: knownFolder,
      );
      return uri.isScheme('file') && isRunnable(uri.toFilePath());
    } on Object {
      return isRunnable(target);
    }
  }

  Future<String> _run(SystemRequest r, AppSettings s) async {
    final dir = s.companionFolder;
    final process = await Process.start(
      Platform.isWindows ? 'powershell' : '/bin/sh',
      Platform.isWindows
          ? ['-NoProfile', '-NonInteractive', '-Command', r.target]
          : ['-c', r.target],
      workingDirectory: dir != null && Directory(dir).existsSync()
          ? dir
          : homeDir,
    );
    // Nothing waits for typed input.
    unawaited(process.stdin.close());
    final out = StringBuffer();
    void collect(String text) {
      if (out.length < maxOutput * 2) out.write(text);
    }

    final done = Future.wait([
      process.stdout.transform(systemEncoding.decoder).forEach(collect),
      process.stderr.transform(systemEncoding.decoder).forEach(collect),
    ]);
    int code;
    var timedOut = false;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      code = await process.exitCode;
    }
    await done.timeout(const Duration(seconds: 2), onTimeout: () => []);
    var text = out.toString();
    final cut = text.length > maxOutput;
    if (cut) text = text.substring(0, maxOutput);
    await _log(
      r,
      timedOut ? 'ran, stopped after ${timeout.inSeconds}s' : 'ran, exit $code',
    );
    return jsonEncode({
      'ok': code == 0 && !timedOut,
      'exit_code': code,
      'output': text,
      if (cut) 'truncated': true,
      if (timedOut) 'error': 'Stopped after ${timeout.inSeconds} seconds.',
    });
  }

  Future<String> _open(SystemRequest r, AppSettings s) async {
    final Uri uri;
    try {
      uri = await resolveTarget(
        r.target,
        s.companionFolder,
        knownFolder: knownFolder,
      );
    } catch (_) {
      // No such file or folder: maybe it names an app.
      if (RegExp(r'[/\\]').hasMatch(r.target)) rethrow;
      final app = await apps.find(r.target);
      if (app == null) rethrow;
      try {
        await startApp(app);
      } catch (e) {
        await _log(r, 'could not start ${app.name}');
        throw 'Could not start ${app.name}: $e';
      }
      await _log(r, 'started ${app.name}');
      return jsonEncode({'ok': true, 'started': app.name});
    }
    final ok = await launcher(uri);
    await _log(r, ok ? 'opened' : 'could not open');
    if (!ok) throw 'Nothing could open ${r.target}';
    return jsonEncode({'ok': true, 'opened': uri.toString()});
  }

  /// A web address as is; anything else is a file or folder: absolute, from
  /// home with `~`, or relative to [folder]. A path that isn't there may
  /// start with one of the human's usual folders by name ("Pictures",
  /// "~/Downloads/x.pdf"), found where the system keeps it (Windows may
  /// keep Pictures in OneDrive; Linux may call it "Bilder"), or be relative
  /// to home.
  static Future<Uri> resolveTarget(
    String target,
    String? folder, {
    Future<String?> Function(String name) knownFolder = userFolder,
  }) async {
    final uri = Uri.tryParse(target);
    if (uri != null &&
        const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
      return uri;
    }
    Uri? at(String path) {
      path = p.normalize(path);
      if (Directory(path).existsSync()) return Uri.directory(path);
      if (File(path).existsSync()) return Uri.file(path);
      return null;
    }

    var rest = target.replaceAll('\\', '/');
    final fromHome = rest == '~' || rest.startsWith('~/');
    if (fromHome) rest = rest.substring(1).replaceFirst(RegExp('^/+'), '');
    final candidates = [
      if (fromHome)
        p.join(homeDir, rest)
      else if (p.isAbsolute(target))
        target
      else ...[
        p.join(folder ?? homeDir, rest),
        p.join(homeDir, rest),
      ],
    ];
    for (final c in candidates) {
      final found = at(c);
      if (found != null) return found;
    }
    if (!p.isAbsolute(target) || fromHome) {
      final parts = rest.split('/').where((x) => x.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        final base = await knownFolder(parts.first);
        final found = base == null
            ? null
            : at(p.joinAll([base, ...parts.skip(1)]));
        if (found != null) return found;
      }
    }
    throw '$target does not exist';
  }

  /// The system's own path for one of the human's usual folders, named as
  /// people say it: Home, Desktop, Documents, Downloads, Music, Pictures
  /// (or Photos), Videos. Null for other names.
  static Future<String?> userFolder(String name) async {
    final key = name.toLowerCase().replaceFirst(RegExp(r'^my\s*'), '');
    if (key == 'home') return homeDir;
    const kinds = {
      'desktop': ('DESKTOP', 'Desktop', 'Desktop'),
      'documents': ('DOCUMENTS', 'MyDocuments', 'Documents'),
      'downloads': ('DOWNLOAD', '', 'Downloads'),
      'music': ('MUSIC', 'MyMusic', 'Music'),
      'pictures': ('PICTURES', 'MyPictures', 'Pictures'),
      'photos': ('PICTURES', 'MyPictures', 'Pictures'),
      'videos': ('VIDEOS', 'MyVideos', 'Videos'),
    };
    final kind = kinds[key];
    if (kind == null) return null;
    final (xdg, windows, plain) = kind;
    String? asked;
    try {
      if (Platform.isWindows && windows.isNotEmpty) {
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "[Environment]::GetFolderPath('$windows')",
        ]);
        asked = (r.stdout as String).trim();
      } else if (Platform.isLinux) {
        final r = await Process.run('xdg-user-dir', [xdg]);
        asked = (r.stdout as String).trim();
        // xdg-user-dir answers home itself for a folder it doesn't know.
        if (asked == homeDir) asked = null;
      }
    } catch (_) {
      // Not available: the usual place below.
    }
    return asked != null && asked.isNotEmpty ? asked : p.join(homeDir, plain);
  }

  Future<void> _log(SystemRequest r, String outcome) async {
    try {
      await logFile.parent.create(recursive: true);
      await logFile.writeAsString(
        '${DateTime.now().toIso8601String()}  ${r.key}  → $outcome'
        '${r.why.isEmpty ? '' : '  (why: ${r.why})'}\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // A log that can't be written never blocks the companion.
    }
  }

  static Future<bool> _launch(Uri uri) => launchUrl(uri);
}
