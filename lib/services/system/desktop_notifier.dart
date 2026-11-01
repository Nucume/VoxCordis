import 'dart:io';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:path/path.dart' as p;

/// Pops up a desktop notification, also while the window is hidden, with
/// what the system already has: notify-send or D-Bus on Linux, a native toast
/// from the Windows runner, osascript on macOS. No plugin, so nothing
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

  static const _channel = MethodChannel('voxcordis/notify');

  /// Called when a Windows toast is clicked, to bring the window back.
  static void Function()? onOpen;

  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'open') onOpen?.call();
    });
  }

  /// [image] is a picture on disk (the companion's portrait), shown beside
  /// the words where the system allows it.
  Future<void> show(String title, String body, {String? image}) async {
    if (image != null && !File(image).existsSync()) image = null;
    final text = body.length > 240 ? '${body.substring(0, 239)}…' : body;
    try {
      if (Platform.isLinux) {
        await _linux(title, text, image);
      } else if (Platform.isWindows) {
        await _windows(title, text, image);
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

  Future<void> _linux(String title, String body, String? picture) async {
    final icon = picture ?? _icon;
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

  /// The app identity Windows files toasts under; the runner registers its
  /// name and icon (windows/runner/toast.cpp) and the process sets the same
  /// one (windows/runner/main.cpp).
  static const windowsAppId = 'com.nucume.companion';

  /// A toast through the runner's own Windows code: no other program runs,
  /// and the words never pass through a script.
  Future<void> _windows(String title, String body, String? image) async {
    _listen();
    await _channel.invokeMethod<bool>('show', {
      'appId': windowsAppId,
      'title': title,
      'body': body,
      'image': image ?? _icon,
      'icon': _icon,
    });
  }
}
