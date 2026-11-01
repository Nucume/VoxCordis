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
  test('the tabs layout survives settings.json, and is the top by default', () {
    expect(AppSettings.fromJson(const {}).settingsTabs, SettingsTabs.top);
    final back = AppSettings.fromJson(
      const AppSettings(settingsTabs: SettingsTabs.side).toJson(),
    );
    expect(back.settingsTabs, SettingsTabs.side);
    expect(
      AppSettings.fromJson(const {'settingsTabs': 'diagonal'}).settingsTabs,
      SettingsTabs.top,
    );
  });

  testWidgets('the side rail opens pages like the top tabs', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('settings_tabs');
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

    await tester.pumpWidget(
      AppScope(
        services: services,
        child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.byType(TabBar), findsOneWidget);

    // Picked in Appearance, it switches at once.
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Across the top'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Down the side').last);
    await tester.pumpAndSettle();
    expect(services.settings.value.settingsTabs, SettingsTabs.side);
    expect(find.byType(TabBar), findsNothing);
    // Still on Appearance.
    expect(find.text('Settings tabs'), findsOneWidget);

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Sam'), findsOneWidget);
  });
}
