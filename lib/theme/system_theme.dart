import 'dart:io';

import 'package:flutter/widgets.dart';

import '../services/system/windows_native.dart';

/// Whether the computer is set to light or dark, for the System theme.
///
/// Flutter reports light whenever the desktop doesn't say (no portal, an
/// unknown desktop, no registry value), but an unknown setting should give
/// the dark look. So light is only used when the OS says so itself, read
/// here; dark from Flutter is always trusted.
class SystemTheme {
  /// The look for the System choice: [platform] is what Flutter reports,
  /// [detected] what the OS said when asked (null when it didn't say).
  static Brightness resolve(Brightness platform, Brightness? detected) {
    if (platform == Brightness.dark) return Brightness.dark;
    return detected ?? Brightness.dark;
  }

  /// Asks the OS. Null when it can't tell.
  static Future<Brightness?> detect() async {
    try {
      if (Platform.isMacOS) {
        // macOS always has a definite appearance, and Flutter reads it.
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
      }
      if (Platform.isWindows) {
        return fromDword(
          await WindowsNative.userDword(
            r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            'AppsUseLightTheme',
          ),
        );
      }
      if (Platform.isLinux) {
        // The desktop portal works on GNOME, KDE and most others; then
        // GNOME's own settings.
        return parsePortal(
              await _run('gdbus', [
                'call',
                '--session',
                '--timeout',
                '2',
                '--dest',
                'org.freedesktop.portal.Desktop',
                '--object-path',
                '/org/freedesktop/portal/desktop',
                '--method',
                'org.freedesktop.portal.Settings.Read',
                'org.freedesktop.appearance',
                'color-scheme',
              ]),
            ) ??
            parseGnomeColorScheme(
              await _run('gsettings', [
                'get',
                'org.gnome.desktop.interface',
                'color-scheme',
              ]),
              gnome: (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '')
                  .toUpperCase()
                  .contains('GNOME'),
            ) ??
            parseGtkTheme(
              await _run('gsettings', [
                'get',
                'org.gnome.desktop.interface',
                'gtk-theme',
              ]),
            );
      }
    } catch (_) {
      // Not there or not allowed: we can't tell.
    }
    return null;
  }

  /// AppsUseLightTheme: 0 is dark, anything else light, null unknown.
  static Brightness? fromDword(int? value) => value == null
      ? null
      : value == 0
      ? Brightness.dark
      : Brightness.light;

  /// The portal's colour scheme, e.g. `(<<uint32 1>>,)`: 1 prefers dark,
  /// 2 prefers light, 0 has no preference.
  static Brightness? parsePortal(String? out) {
    final m = RegExp(r'uint32\s+(\d+)').firstMatch(out ?? '');
    return switch (m?[1]) {
      '1' => Brightness.dark,
      '2' => Brightness.light,
      _ => null,
    };
  }

  /// GNOME's `'prefer-dark'`, `'prefer-light'` or `'default'`. On GNOME
  /// itself `'default'` is what the Light button in its settings picks;
  /// elsewhere it only means nobody chose.
  static Brightness? parseGnomeColorScheme(String? out, {bool gnome = false}) {
    final v = out?.trim().replaceAll("'", '');
    return switch (v) {
      'prefer-dark' => Brightness.dark,
      'prefer-light' => Brightness.light,
      'default' when gnome => Brightness.light,
      _ => null,
    };
  }

  /// Only a theme named as dark (e.g. `'Adwaita-dark'`) says anything.
  static Brightness? parseGtkTheme(String? out) {
    final v = out?.trim().replaceAll("'", '').toLowerCase() ?? '';
    return v.endsWith('-dark') || v.endsWith(':dark') ? Brightness.dark : null;
  }

  static Future<String?> _run(String exe, List<String> args) async {
    final r = await Process.run(exe, args).timeout(const Duration(seconds: 3));
    return r.exitCode == 0 ? '${r.stdout}' : null;
  }
}
