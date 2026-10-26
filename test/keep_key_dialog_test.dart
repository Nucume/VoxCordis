import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/keep_key_dialog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  testWidgets('Continue waits until the key is copied', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('keep_key');
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
          AppSettings(companionName: 'Aria'),
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
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showKeepKey(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Keep a copy of your key'), findsOneWidget);

    FilledButton continueButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    expect(continueButton().onPressed, isNull);

    // Tapping outside doesn't close it either.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Keep a copy of your key'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Copy the key'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Copied.'), findsOneWidget);
    expect(continueButton().onPressed, isNotNull);

    await tester.runAsync(() async {
      await tester.tap(find.text('Continue'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Keep a copy of your key'), findsNothing);
    expect(services.dbKey.saved, isTrue);
  });
}
