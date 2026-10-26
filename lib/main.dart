import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'app.dart';
import 'app_scope.dart';
import 'data/database_key.dart';
import 'features/unlock/unlock_app.dart';
import 'services/changelog.dart';
import 'services/system/background.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _makeWindowTranslucent();
  final dir = await AppServices.supportDir();
  final key = DatabaseKey(dir);
  // Started by the login item: out of the way once the window is up.
  final hidden = args.contains(Background.startHiddenArg);
  if (await key.unlock()) return _start(dir, key, startHidden: hidden);
  // Encrypted chats without their key here: ask for it first.
  runApp(UnlockApp(dbKey: key, onUnlocked: () => _start(dir, key)));
}

Future<void> _start(
  Directory dir,
  DatabaseKey key, {
  bool startHidden = false,
}) async {
  final services = await AppServices.open(dir, key);
  Future<void> beforeQuit() async {
    services.webTools.close();
    await services.runtime.stopAll();
  }

  // Never leave a llama-server or the browser running after the window
  // closes.
  AppLifecycleListener(
    onExitRequested: () async {
      await beforeQuit();
      return AppExitResponse.exit;
    },
  );
  // With "Close to the system tray" on, closing the window only hides it.
  services.background = Background(
    settings: services.settings,
    beforeQuit: beforeQuit,
  );
  await services.background!.start(startHidden: startHidden);
  // Before setup can run, so a fresh install never counts as an update.
  services.whatsNew = await WhatsNew.inSupportDir(
    services.runtime.supportDir,
  ).pending(wasSetUp: services.settings.value.isSetUp);
  // Warm the model up while the window opens.
  if (services.settings.value.isSetUp) {
    services.runtime.ensureReady(services.settings.value).ignore();
    // With "free the graphics card" on, it lets go again if nobody types.
    services.runtime.touch(services.settings.value);
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
