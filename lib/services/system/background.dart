import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../data/settings.dart';
import '../folder_service.dart';

/// Keeps VoxCordis running when its window is closed, so reminders and
/// automations still happen: with Settings → General → "Keep running"
/// on, closing the window minimizes it to the taskbar instead, and Quit
/// in Settings really closes it. Also starts it with the computer.
class Background with WindowListener {
  Background({required this.settings, required this.beforeQuit});

  final SettingsStore settings;

  /// Stops the model and anything else before the app quits.
  final Future<void> Function() beforeQuit;

  /// The argument the login item starts VoxCordis with.
  static const startHiddenArg = '--background';

  /// The smallest the window may get: room for the companion card, the
  /// tabs and a readable chat, and still fits a 1366×768 laptop screen.
  static const minWindowSize = Size(980, 640);

  bool _ready = false;
  bool _keepRunning = false;

  /// Hooks into the window. [startHidden] when the computer started it.
  Future<void> start({bool startHidden = false}) async {
    try {
      await windowManager.ensureInitialized();
      // Below this the card, the tabs and the chat squeeze into each other.
      await windowManager.setMinimumSize(minWindowSize);
      windowManager.addListener(this);
      _ready = true;
      await _apply();
      settings.addListener(_onSettings);
      if (startHidden && settings.value.keepRunning) {
        // Once the first frame is up, out of the way.
        Future.delayed(const Duration(seconds: 2), windowManager.minimize);
      }
    } on Object catch (e) {
      debugPrint('Window hooks unavailable: $e');
    }
    await syncLoginItem(settings.value.startWithComputer).catchError((_) {});
  }

  void _onSettings() {
    final s = settings.value;
    if (s.keepRunning != _keepRunning) _apply().ignore();
    if (s.startWithComputer != _loginItem) {
      syncLoginItem(s.startWithComputer).ignore();
    }
  }

  Future<void> _apply() async {
    _keepRunning = settings.value.keepRunning;
    if (_ready) await windowManager.setPreventClose(_keepRunning);
  }

  /// Whether the window has the keyboard focus, so a notification would
  /// only repeat what is on screen.
  Future<bool> windowFocused() async {
    if (!_ready) return false;
    try {
      return await windowManager.isFocused() &&
          !await windowManager.isMinimized();
    } on Object {
      return false;
    }
  }

  /// Brings the window back, e.g. for an approval.
  Future<void> showWindow() async {
    if (!_ready) return;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    if (_keepRunning) {
      await windowManager.minimize();
      return;
    }
    await quit();
  }

  /// Really closes VoxCordis, also with "Keep running" on.
  Future<void> quit() async {
    await beforeQuit().catchError((_) {});
    if (_ready) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } else {
      exit(0);
    }
  }

  bool? _loginItem;

  /// The command that starts this copy of VoxCordis: the AppImage itself
  /// when it runs from one (the binary inside lives in a temporary mount).
  static String get launchCommand =>
      Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable;

  static String get _linuxAutostart => p.join(
    Platform.environment['XDG_CONFIG_HOME'] ?? p.join(homeDir, '.config'),
    'autostart',
    'com.nucume.companion.desktop',
  );

  static const _windowsRunKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// Adds or removes VoxCordis from what starts when the human logs in.
  Future<void> syncLoginItem(bool on) async {
    _loginItem = on;
    if (Platform.isLinux) {
      final file = File(_linuxAutostart);
      if (on) {
        await file.parent.create(recursive: true);
        await file.writeAsString(linuxAutostartEntry(launchCommand));
      } else if (await file.exists()) {
        await file.delete();
      }
    } else if (Platform.isWindows) {
      await Process.run('reg', [
        if (on) ...[
          'add',
          _windowsRunKey,
          '/v',
          'VoxCordis',
          '/t',
          'REG_SZ',
          '/d',
          '"$launchCommand" $startHiddenArg',
          '/f',
        ] else ...[
          'delete',
          _windowsRunKey,
          '/v',
          'VoxCordis',
          '/f',
        ],
      ]);
    }
  }

  /// The autostart .desktop file for [command], quoted as the spec asks.
  static String linuxAutostartEntry(String command) {
    final quoted =
        '"${command.replaceAll(r'\', r'\\\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$').replaceAll('`', r'\`')}"';
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=VoxCordis\n'
        'Comment=Keeps your companion\'s reminders running\n'
        'Exec=$quoted $startHiddenArg\n'
        'Icon=com.nucume.companion\n'
        'X-GNOME-Autostart-enabled=true\n'
        'Terminal=false\n';
  }
}
