import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/features/unlock/unlock_app.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  testWidgets('asks for the key and opens with the right one', (tester) async {
    final dir = Directory.systemTemp.createTempSync('unlock');
    addTearDown(() => dir.deleteSync(recursive: true));
    final secrets = SecretStore(
      Directory(p.join(dir.path, 'secrets')),
      system: false,
    );
    late DatabaseKey key;
    await tester.runAsync(() async {
      final db = await openAppDatabase(
        p.join(dir.path, 'companion.db'),
        key: 'the real key',
      );
      await db.close();
      key = DatabaseKey(dir, secrets: secrets);
      expect(await key.unlock(), isFalse);
    });

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var unlocked = 0;
    await tester.pumpWidget(
      UnlockApp(dbKey: key, onUnlocked: () => unlocked++),
    );
    expect(find.text('Unlock your chats'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'a guess');
    await tester.runAsync(() async {
      await tester.tap(find.text('Unlock'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.textContaining("That isn't the key"), findsOneWidget);
    expect(unlocked, 0);

    await tester.enterText(find.byType(TextField), 'the real key');
    await tester.runAsync(() async {
      await tester.tap(find.text('Unlock'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(unlocked, 1);
    expect(key.value, 'the real key');
  });
}
