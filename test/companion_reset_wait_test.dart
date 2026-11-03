import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/delete_companion_dialog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  testWidgets('Reset and Delete wait while the companion is replying', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('reset_wait');
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
          const AppSettings(companionName: 'Aria'),
        ),
        db: await openAppDatabase(
          AppServices.companionDbPath(dir.path, null),
          key: key.value,
        ),
        runtime: RuntimeController(dir),
        dbKey: key,
      );
    });

    var replying = true;
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => confirmResetCompanion(
                      context,
                      replying: () => replying,
                    ),
                    child: const Text('reset'),
                  ),
                  TextButton(
                    onPressed: () => confirmDeleteCompanion(
                      context,
                      replying: () => replying,
                    ),
                    child: const Text('delete'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('reset'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Aria?'), findsNothing);
    expect(find.text('Let Aria finish replying first.'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.text('reset')),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Aria?'), findsNothing);
    expect(find.text('Let Aria finish replying first.'), findsOneWidget);

    // Once the reply is done, they ask as before.
    replying = false;
    await tester.tap(find.text('reset'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Aria?'), findsOneWidget);
  });
}
