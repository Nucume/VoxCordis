import 'package:companion/data/settings.dart';
import 'package:companion/theme/app_theme.dart';
import 'package:companion/theme/system_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('system theme', () {
    test('light only when the OS says so, dark otherwise', () {
      const light = Brightness.light, dark = Brightness.dark;
      expect(SystemTheme.resolve(dark, null), dark);
      expect(SystemTheme.resolve(dark, light), dark);
      // Flutter says light when it can't tell.
      expect(SystemTheme.resolve(light, null), dark);
      expect(SystemTheme.resolve(light, light), light);
      expect(SystemTheme.resolve(light, dark), dark);
    });

    test('reads the Windows registry value', () {
      const head =
          r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion'
          r'\Themes\Personalize';
      expect(
        SystemTheme.parseWindows(
          '$head\n    AppsUseLightTheme    REG_DWORD    0x0\n',
        ),
        Brightness.dark,
      );
      expect(
        SystemTheme.parseWindows(
          '$head\n    AppsUseLightTheme    REG_DWORD    0x1\n',
        ),
        Brightness.light,
      );
      expect(SystemTheme.parseWindows(null), isNull);
      expect(SystemTheme.parseWindows('ERROR: not found'), isNull);
    });

    test('reads the desktop portal', () {
      expect(SystemTheme.parsePortal('(<<uint32 1>>,)'), Brightness.dark);
      expect(SystemTheme.parsePortal('(<<<uint32 2>>>,)'), Brightness.light);
      expect(SystemTheme.parsePortal('(<<uint32 0>>,)'), isNull);
      expect(SystemTheme.parsePortal(null), isNull);
    });

    test('reads GNOME settings', () {
      expect(
        SystemTheme.parseGnomeColorScheme("'prefer-dark'\n"),
        Brightness.dark,
      );
      expect(
        SystemTheme.parseGnomeColorScheme("'prefer-light'"),
        Brightness.light,
      );
      // GNOME's Light button sets 'default'; elsewhere nobody chose.
      expect(
        SystemTheme.parseGnomeColorScheme("'default'", gnome: true),
        Brightness.light,
      );
      expect(SystemTheme.parseGnomeColorScheme("'default'"), isNull);
      expect(SystemTheme.parseGtkTheme("'Adwaita-dark'"), Brightness.dark);
      expect(SystemTheme.parseGtkTheme("'Adwaita'"), isNull);
    });
  });

  test('the theme choice is saved, and System is the default', () {
    expect(const AppSettings().themeChoice, ThemeChoice.system);
    expect(AppSettings.fromJson(const {}).themeChoice, ThemeChoice.system);
    final s = const AppSettings().copyWith(themeChoice: ThemeChoice.light);
    expect(AppSettings.fromJson(s.toJson()).themeChoice, ThemeChoice.light);
    expect(
      AppSettings.fromJson(const {'themeChoice': 'nonsense'}).themeChoice,
      ThemeChoice.system,
    );
  });

  test('both looks carry their palette', () {
    final light = AppTheme.build(const Color(0xFFB18CFF), Brightness.light);
    final dark = AppTheme.build(const Color(0xFFB18CFF), Brightness.dark);
    expect(light.extension<AppPalette>(), AppPalette.light);
    expect(dark.extension<AppPalette>(), AppPalette.dark);
    expect(light.colorScheme.brightness, Brightness.light);
  });

  test('light text is readable on a light panel', () {
    // A panel over the base, without glows: the worst case is a glow-free
    // spot, since the glows are pale tints on light.
    final panel = Color.alphaBlend(
      AppPalette.light.glass,
      AppPalette.light.background,
    );
    final muted = Color.alphaBlend(AppPalette.light.textMuted, panel);
    expect(_contrast(muted, panel), greaterThan(4.5));
    expect(_contrast(AppPalette.light.text, panel), greaterThan(7));
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
