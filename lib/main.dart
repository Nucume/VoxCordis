import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'app.dart';
import 'app_scope.dart';
import 'data/database_key.dart';
import 'features/unlock/unlock_app.dart';
import 'services/changelog.dart';
import 'services/logs/app_log.dart';
import 'services/system/background.dart';
import 'services/system/desktop_entry.dart';
import 'shell/window_frame.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _makeWindowTranslucent();
  final dir = await AppServices.supportDir();
  // VoxCordis' own title bar, unless the system's was chosen.
  await TitleBarChoice.load(dir);
  // Linux: the icon for Alt+Tab and the taskbar.
  DesktopEntry.install().ignore();
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
    await services.webTools.close();
    await services.runtime.stopAll();
    await services.log.flush();
  }

  // Errors nothing else caught go to Settings → Logs as well.
  final flutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    services.log.add(
      LogKind.errors,
      details.exceptionAsString(),
      details: '${details.stack ?? ''}',
      error: true,
    );
    flutterError?.call(details);
  };
  final platformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    services.log.add(LogKind.errors, '$error', details: '$stack', error: true);
    return platformError?.call(error, stack) ?? false;
  };

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
  // Memories and chat that have no vector yet (after an update, or an
  // import) are embedded once the window is up.
  Future.delayed(const Duration(seconds: 20), services.recall.update);
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
