import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';
import 'package:companion/shell/companion_switcher.dart';

void main() {
  late Directory dir;
  late AppServices services;
  late ChatController chat;
  Completer<bool>? leave;

  /// Aria is current, Mira waits; [told] is whether the one-companion
  /// notice was already shown.
  Future<void> openMenu(WidgetTester tester, {bool told = true}) async {
    dir = Directory.systemTemp.createTempSync('switch_wait');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final key = DatabaseKey(
        dir,
        secrets: SecretStore(
          Directory(p.join(dir.path, 'secrets')),
          system: false,
        ),
      );
      await key.unlock();
      services = AppServices(
        settings: SettingsStore(
          File(p.join(dir.path, 'settings.json')),
          AppSettings(
            companionName: 'Aria',
            companionFolder: p.join(dir.path, 'Aria'),
            toldAboutMoreCompanions: told,
            otherCompanions: [
              CompanionProfile(
                id: 'mira-id',
                name: 'Mira',
                folder: p.join(dir.path, 'Mira'),
              ),
            ],
          ),
        ),
        db: await openAppDatabase(
          AppServices.companionDbPath(dir.path, null),
          key: key.value,
        ),
        runtime: RuntimeController(dir),
        dbKey: key,
      );
    });
    addTearDown(() => tester.runAsync(services.db.close));
    chat = ChatController(services);
    leave = null;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          home: Scaffold(
            body: CompanionSwitcher(
              chat: chat,
              // Settings asks about unsaved changes; the test answers.
              mayLeave: () => (leave = Completer<bool>()).future,
              builder: (context, open) =>
                  const SizedBox(width: 260, child: Text('menu')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
  }

  testWidgets('switching waits for a reply that started while Settings asked', (
    tester,
  ) async {
    await openMenu(tester);
    await tester.tap(find.text('Mira'));
    await tester.pumpAndSettle();
    expect(leave, isNotNull);

    // A reminder starts a reply while the Save dialog is open.
    chat.busy = true;
    leave!.complete(true);
    await tester.pumpAndSettle();
    // Gives a switch, were one started, the time to open Mira's database.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    expect(services.settings.value.companionName, 'Aria');
    expect(services.settings.value.companionId, isNull);
    expect(find.text('Let Aria finish replying first.'), findsOneWidget);
  });

  testWidgets('adding waits for a reply that started while Settings asked', (
    tester,
  ) async {
    await openMenu(tester);
    await tester.tap(find.text('Add another companion'));
    await tester.pumpAndSettle();
    expect(leave, isNotNull);

    chat.busy = true;
    leave!.complete(true);
    await tester.pumpAndSettle();

    expect(services.addingCompanion.value, isFalse);
    expect(find.text('Let Aria finish replying first.'), findsOneWidget);
  });

  testWidgets('adding waits for a reply that started during the notice', (
    tester,
  ) async {
    await openMenu(tester, told: false);
    await tester.tap(find.text('Add another companion'));
    await tester.pumpAndSettle();
    leave!.complete(true);
    // The notice's heart beats on, so it never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('VoxCordis is made for one companion'), findsOneWidget);

    chat.busy = true;
    await tester.tap(find.text('Add another anyway'));
    await tester.pumpAndSettle();

    expect(services.addingCompanion.value, isFalse);
    expect(find.text('Let Aria finish replying first.'), findsOneWidget);
  });
}
