import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'data/looks.dart';
import 'data/settings.dart';
import 'features/setup/setup_wizard.dart';
import 'features/voces/voces_home.dart';
import 'shell/home_shell.dart';
import 'shell/interface_scale.dart';
import 'shell/window_frame.dart';
import 'theme/app_theme.dart';
import 'theme/system_theme.dart';

class CompanionApp extends StatefulWidget {
  const CompanionApp({super.key});

  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp>
    with WidgetsBindingObserver {
  /// What the OS last said, for the System choice; null until asked or
  /// when it doesn't say.
  Brightness? _detected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _detect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The OS switched: ask again, since Flutter alone can't tell light from
  // "doesn't say".
  @override
  void didChangePlatformBrightness() => _detect();

  Future<void> _detect() async {
    final b = await SystemTheme.detect();
    if (mounted) setState(() => _detected = b);
  }

  Brightness _brightness(ThemeChoice choice) => switch (choice) {
    ThemeChoice.light => Brightness.light,
    ThemeChoice.dark => Brightness.dark,
    ThemeChoice.system => SystemTheme.resolve(
      MediaQuery.platformBrightnessOf(context),
      _detected,
    ),
  };

  ThemeData? _theme;
  (Color, Brightness, Look?, List<int>)? _themeFrom;

  /// The theme for this look, built once and kept until the look changes:
  /// this widget builds again on every settings save, and most of those
  /// have nothing to do with colours.
  ThemeData _themeFor(
    Color accent,
    Brightness brightness,
    Look? colorway,
    List<int> glows,
  ) {
    if ((_theme, _themeFrom) case (final theme?, final from?)
        when from.$1 == accent &&
            from.$2 == brightness &&
            identical(from.$3, colorway) &&
            listEquals(from.$4, glows)) {
      return theme;
    }
    _themeFrom = (accent, brightness, colorway, glows);
    return _theme = AppTheme.build(
      accent,
      brightness,
      colorway: colorway,
      glows: [for (final c in glows) Color(c)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final settings = services.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([
        settings,
        services.addingCompanion,
        services.vocesOpen,
        services.backgroundRevision,
        services.resets,
      ]),
      builder: (context, _) {
        final adding = services.addingCompanion.value;
        final setup = settings.value.companionFolder == null || adding;
        final brightness = _brightness(settings.value.themeChoice);
        final colorway = Look.byId(settings.value.colorway);
        // A special colorway brings its own accent and glows for the light
        // theme; the stored ones are its dark-theme colours.
        final lightColorway =
            brightness == Brightness.light &&
            colorway != null &&
            colorway.isSpecial;
        final accent = Color(
          lightColorway
              ? colorway.accentIn(light: true)
              : settings.value.accentColor,
        );
        final glows = lightColorway
            ? colorway.colorsIn(light: true)
            : settings.value.backgroundColors;
        return MaterialApp(
          navigatorKey: services.navigatorKey,
          title: settings.value.companionName,
          debugShowCheckedModeBanner: false,
          theme: _themeFor(accent, brightness, colorway, glows),
          color: Colors.transparent,
          // The background under everything, the title bar included, and
          // the pages under the title bar.
          builder: (context, navigator) => InterfaceScale(
            scale: settings.value.interfaceScale,
            child: WindowCorners(
              child: AuroraBackground(
                accent: accent,
                colors: [for (final c in glows) Color(c)],
                layout:
                    settings.value.backgroundLayout ??
                    AuroraBackground.defaultLayout,
                // Moving only during setup: it costs the graphics card the
                // model needs.
                animate: setup,
                child: WindowFrame(child: navigator!),
              ),
            ),
          ),
          // First run (no home folder yet) goes through setup, and so does
          // adding another companion. The window is rebuilt for each
          // companion, so nothing of the last one stays on screen.
          home: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: setup
                ? SetupWizard(key: ValueKey(adding), addingAnother: adding)
                : services.vocesOpen.value && settings.value.vocesMundi
                ? const VocesHome(key: ValueKey('voces'))
                : HomeShell(
                    key: ValueKey(
                      'companion:${settings.value.companionId}:'
                      '${services.resets.value}',
                    ),
                  ),
          ),
        );
      },
    );
  }
}
