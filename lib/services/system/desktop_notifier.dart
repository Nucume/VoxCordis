import 'dart:io';

import 'package:path/path.dart' as p;

/// Pops up a desktop notification, also while the window is hidden, with
/// what the system already has: notify-send or D-Bus on Linux, a toast
/// through PowerShell on Windows, osascript on macOS. No plugin, so nothing
/// new to build or bundle. A notification that can't be shown is skipped:
/// the message is in the chat either way.
class DesktopNotifier {
  const DesktopNotifier({this.run = Process.run});

  /// Runs a program; replaced in tests.
  final Future<ProcessResult> Function(
    String exe,
    List<String> args, {
    Map<String, String>? environment,
  })
  run;

  static String? get _icon {
    final icon = p.join(
      p.dirname(Platform.resolvedExecutable),
      'data',
      'flutter_assets',
      'assets',
      'brand',
      'app_icon.png',
    );
    return File(icon).existsSync() ? icon : null;
  }

  Future<void> show(String title, String body) async {
    final text = body.length > 240 ? '${body.substring(0, 239)}…' : body;
    try {
      if (Platform.isLinux) {
        await _linux(title, text);
      } else if (Platform.isWindows) {
        await _windows(title, text);
      } else if (Platform.isMacOS) {
        await run('osascript', [
          '-e',
          'on run argv\ndisplay notification (item 2 of argv) with title '
              '(item 1 of argv)\nend run',
          title,
          text,
        ]);
      }
    } on Object {
      // No notification service: the chat still has the message.
    }
  }

  Future<void> _linux(String title, String body) async {
    final icon = _icon;
    final r = await run('notify-send', [
      '--app-name=VoxCordis',
      if (icon != null) '--icon=$icon',
      '--',
      title,
      body,
    ]);
    if (r.exitCode == 0) return;
    // notify-send isn't installed everywhere; gdbus comes with GLib.
    await run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.Notifications',
      '--object-path',
      '/org/freedesktop/Notifications',
      '--method',
      'org.freedesktop.Notifications.Notify',
      'VoxCordis',
      '0',
      gvariantString(icon ?? ''),
      gvariantString(title),
      gvariantString(body),
      '[]',
      '{}',
      '-1',
    ]);
  }

  /// [s] as a GVariant text string, which is how gdbus reads arguments.
  static String gvariantString(String s) =>
      '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';

  /// A toast through the Windows Runtime. The words go in environment
  /// variables, never in the script, so nothing in them can run.
  Future<void> _windows(String title, String body) => run(
    'powershell',
    [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-Command',
      r'''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $xml.GetElementsByTagName('text')
$t.Item(0).AppendChild($xml.CreateTextNode($env:VC_TITLE)) | Out-Null
$t.Item(1).AppendChild($xml.CreateTextNode($env:VC_BODY)) | Out-Null
$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
''',
    ],
    environment: {'VC_TITLE': title, 'VC_BODY': body},
  );
}
