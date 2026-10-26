import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/encryption_settings.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  testWidgets('shows the key and takes an own password', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('enc_settings');
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
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: EncryptionSettings()),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final first = services.dbKey.value;
    expect(find.text(first), findsNothing);
    expect(
      find.textContaining('kept in a file only your account'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Show the key'));
    await tester.pump();
    expect(find.text(first), findsOneWidget);

    await tester.tap(find.text('Use my own password'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'short');
    await tester.enterText(fields.at(1), 'short');
    await tester.tap(find.text('Use it'));
    await tester.pump();
    expect(find.textContaining('at least 8'), findsOneWidget);

    await tester.enterText(fields.at(0), 'correct horse battery');
    await tester.enterText(fields.at(1), 'correct horse battery');
    await tester.tap(find.text('Use it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Re-encrypting starts (companions_test checks the result on disk).
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
