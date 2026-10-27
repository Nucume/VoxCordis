import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/settings_screen.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  testWidgets('asks before leaving Settings with unsaved changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('settings_leave');
    addTearDown(() => dir.deleteSync(recursive: true));
    late AppServices services;
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
          AppSettings(companionName: 'Aria', userName: 'Sam'),
        ),
        db: await openAppDatabase(
          AppServices.companionDbPath(dir.path, null),
          key: key.value,
        ),
        runtime: RuntimeController(dir),
        dbKey: key,
      );
    });

    final settings = GlobalKey<SettingsScreenState>();
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          home: Scaffold(body: SettingsScreen(key: settings)),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    // Opens on General, and nothing changed yet: leaving asks nothing.
    expect(find.widgetWithText(TextField, 'Sam'), findsOneWidget);
    expect(settings.currentState!.changed, isFalse);
    expect(await settings.currentState!.mayLeave(), isTrue);

    await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Sammy');
    expect(settings.currentState!.changed, isTrue);

    // Cancel stays.
    var leave = settings.currentState!.mayLeave();
    await tester.pumpAndSettle();
    expect(find.text('Save your changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await leave, isFalse);

    // Discard goes, and keeps the saved name.
    leave = settings.currentState!.mayLeave();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(await leave, isTrue);
    expect(services.settings.value.userName, 'Sam');
  });
}
