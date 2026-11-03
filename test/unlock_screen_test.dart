import 'dart:async';
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

  // How often the screen looks for the stored key by itself.
  const retryEvery = Duration(seconds: 5);

  group('looking for the stored key by itself', () {
    late _HeldKey key;
    var unlocked = 0;

    Future<void> show(WidgetTester tester) async {
      final dir = Directory.systemTemp.createTempSync('unlock');
      addTearDown(() => dir.deleteSync(recursive: true));
      key = _HeldKey(
        dir,
        secrets: SecretStore(
          Directory(p.join(dir.path, 'secrets')),
          system: false,
        ),
      );
      unlocked = 0;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UnlockApp(dbKey: key, onUnlocked: () => unlocked++),
      );
      // Stops the looks before the test ends.
      addTearDown(() => tester.pumpWidget(const SizedBox()));
    }

    bool fieldReady(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).enabled != false &&
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus;

    testWidgets('never gets in the way of typing the key', (tester) async {
      await show(tester);
      await tester.enterText(find.byType(TextField), 'half a k');
      expect(fieldReady(tester), isTrue);

      await tester.pump(retryEvery);
      expect(key.looks, hasLength(1));
      expect(fieldReady(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      key.looks.single.complete(false);
      await tester.pump();
      expect(fieldReady(tester), isTrue);
      expect(find.textContaining('still isn'), findsNothing);
      expect(unlocked, 0);
    });

    testWidgets('stops while asking whether to start over', (tester) async {
      await show(tester);
      await tester.tap(find.text('I lost the key'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(retryEvery * 3);
      expect(key.looks, isEmpty);

      await tester.tap(find.text('Start over'));
      await tester.pump();
      expect(key.setAsides, 1);
      expect(unlocked, 1);
    });

    testWidgets('a key found while asking means no start over', (tester) async {
      await show(tester);
      await tester.pump(retryEvery);
      expect(key.looks, hasLength(1));
      await tester.tap(find.text('I lost the key'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // The keyring opens while the question is up.
      key.looks.single.complete(true);
      await tester.pump();
      expect(unlocked, 1);

      await tester.tap(find.text('Start over'));
      await tester.pump();
      expect(key.setAsides, 0);
      expect(unlocked, 1);
    });

    testWidgets('a start over that fails can be tried again', (tester) async {
      await show(tester);
      key.setAsideFails = true;
      await tester.tap(find.text('I lost the key'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Start over'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining("couldn't be moved aside"), findsOneWidget);
      expect(unlocked, 0);
      expect(fieldReady(tester), isTrue);

      // The looks for the stored key carry on.
      await tester.pump(retryEvery);
      expect(key.looks, hasLength(1));
      key.looks.single.complete(false);
      await tester.pump();

      key.setAsideFails = false;
      await tester.tap(find.text('I lost the key'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Start over'));
      await tester.pump();
      expect(key.setAsides, 2);
      expect(unlocked, 1);
    });
  });
}

/// A key whose stored copy is looked for only when the test says so.
class _HeldKey extends DatabaseKey {
  _HeldKey(super.supportDir, {super.secrets});

  final looks = <Completer<bool>>[];
  int setAsides = 0;

  /// Moving the chats aside fails, as when another program holds a file.
  bool setAsideFails = false;

  @override
  Future<bool> unlock() {
    final look = Completer<bool>();
    looks.add(look);
    return look.future;
  }

  @override
  Future<Directory> setAside() async {
    setAsides++;
    if (setAsideFails) {
      throw const FileSystemException('The file is in use');
    }
    return supportDir;
  }
}
