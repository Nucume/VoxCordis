import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../data/settings.dart';
import '../folder_service.dart';
import 'tray.dart';

/// Keeps VoxCordis running when its window is closed, so reminders and
/// automations still happen: with Settings → General → "Close to the system
/// tray" on, closing the window hides it behind a tray icon ([Tray]), or
/// minimizes it where there is no tray. Quit in the tray menu or Settings
/// really closes it. Also starts it with the computer.
class Background with WindowListener {
  Background({required this.settings, required this.beforeQuit});

  final SettingsStore settings;

  /// Stops the model and anything else before the app quits.
  final Future<void> Function() beforeQuit;

  /// The argument the login item starts VoxCordis with.
  static const startHiddenArg = '--background';

  /// The smallest the window may get: room for the companion card with its
  /// portrait, every tab with its name and a readable chat, and still fits
  /// a 1366×768 laptop screen.
  static const minWindowSize = Size(1140, 720);

  bool _ready = false;
  bool _keepRunning = false;

  /// The tray icon while "Close to system tray" is on and there is a tray.
  Tray? _tray;
  bool _inTray = false;

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
        Future.delayed(const Duration(seconds: 2), _putAway);
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
    if (!_ready) return;
    await windowManager.setPreventClose(_keepRunning);
    if (_keepRunning) {
      _tray ??= Tray.forPlatform(
        onOpen: () => showWindow().ignore(),
        onQuit: () => quit().ignore(),
      );
      _inTray = await _tray?.show() ?? false;
    } else {
      await _tray?.hide();
      _inTray = false;
    }
  }

  /// Whether closing the window puts it in the tray (rather than the
  /// taskbar, where there is no tray to put it in).
  bool get inTray => _inTray;

  /// Out of the way: into the tray, or down to the taskbar without one.
  Future<void> _putAway() async {
    if (_inTray) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  /// Whether the window has the keyboard focus, so a notification would
  /// only repeat what is on screen.
  Future<bool> windowFocused() async {
    if (!_ready) return false;
    try {
      return await windowManager.isVisible() &&
          await windowManager.isFocused() &&
          !await windowManager.isMinimized();
    } on Object {
      return false;
    }
  }

  /// Brings the window back, e.g. for an approval.
  Future<void> showWindow() async {
    if (!_ready) return;
    if (!await windowManager.isVisible()) await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    if (_keepRunning) {
      await _putAway();
      return;
    }
    await quit();
  }

  /// Really closes VoxCordis, also with "Close to the system tray" on.
  Future<void> quit() async {
    await beforeQuit().catchError((_) {});
    await _tray?.hide().catchError((_) {});
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

  /// [command] quoted for a .desktop file's Exec line, as the spec asks.
  static String quoteExec(String command) =>
      '"${command.replaceAll(r'\', r'\\\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$').replaceAll('`', r'\`')}"';

  /// The autostart .desktop file for [command], quoted as the spec asks.
  static String linuxAutostartEntry(String command) {
    final quoted = quoteExec(command);
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
