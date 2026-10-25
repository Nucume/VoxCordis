import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'app.dart';
import 'app_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _makeWindowTranslucent();
  final services = await AppServices.open();
  // Never leave a llama-server running after the window closes.
  AppLifecycleListener(
    onExitRequested: () async {
      await services.runtime.stop();
      return AppExitResponse.exit;
    },
  );
  // Warm the model up while the window opens.
  if (services.settings.value.isSetUp) {
    services.runtime.ensureReady(services.settings.value).ignore();
    services.rewriteIfAsked().ignore();
  }
  runApp(AppScope(services: services, child: const CompanionApp()));
  // One quiet look for a newer release once the window is up.
  Future.delayed(const Duration(seconds: 3), services.updates.check);
}

/// Real Mica/Acrylic on Windows, vibrancy on macOS. On Linux the runner
/// (my_application.cc) makes the window transparent itself, because the
/// plugin's Linux code drops keyboard focus; the compositor decides whether
/// it blurs (KDE does).
Future<void> _makeWindowTranslucent() async {
  if (Platform.isLinux) return;
  try {
    await Window.initialize();
    final effect = Platform.isWindows
        ? WindowEffect.mica
        : WindowEffect.underWindowBackground;
    await Window.setEffect(effect: effect, dark: true);
  } catch (_) {
    // Effects are cosmetic; the aurora background covers for them.
  }
}
