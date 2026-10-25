import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'data/settings.dart';
import 'features/setup/setup_wizard.dart';
import 'shell/home_shell.dart';
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

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final settings = services.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, services.addingCompanion]),
      builder: (context, _) {
        final adding = services.addingCompanion.value;
        final setup = settings.value.companionFolder == null || adding;
        final accent = Color(settings.value.accentColor);
        return MaterialApp(
          title: settings.value.companionName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            accent,
            _brightness(settings.value.themeChoice),
          ),
          color: Colors.transparent,
          home: AuroraBackground(
            accent: accent,
            colors: [for (final c in settings.value.backgroundColors) Color(c)],
            layout:
                settings.value.backgroundLayout ??
                AuroraBackground.defaultLayout,
            // Moving only during setup: it costs the graphics card the model
            // needs.
            animate: setup,
            // First run (no home folder yet) goes through setup, and so
            // does adding another companion. The window is rebuilt for each
            // companion, so nothing of the last one stays on screen.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: setup
                  ? SetupWizard(key: ValueKey(adding), addingAnother: adding)
                  : HomeShell(
                      key: ValueKey('companion:${settings.value.companionId}'),
                    ),
            ),
          ),
        );
      },
    );
  }
}
