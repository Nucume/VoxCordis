import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_screen.dart';
import 'package:companion/features/images/images_screen.dart';
import 'package:companion/features/images/lora_grid.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';
import 'package:companion/shell/companion_card.dart';
import 'package:companion/shell/home_shell.dart';
import 'package:companion/theme/app_theme.dart';

void main() {
  late Directory dir;
  late AppServices services;

  Future<void> start(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    dir = Directory.systemTemp.createTempSync('compact');
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
      await key.markSaved();
      services = AppServices(
        settings: SettingsStore(
          File(p.join(dir.path, 'settings.json')),
          AppSettings(
            companionName: 'Aria',
            companionFolder: p.join(dir.path, 'Aria'),
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
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: AppTheme.dark(const Color(0xFF8B7CF6)),
          home: const HomeShell(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    // The chat loads from the database.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> resize(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 720);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Takes the shell down, so its timers stop.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  }

  final card = find.byType(CompanionCard);
  final menu = find.byIcon(Icons.menu_rounded);

  testWidgets('the card stays beside the panel while there is room', (
    tester,
  ) async {
    await start(tester, HomeShell.roomForCard);
    expect(card, findsOneWidget);
    expect(menu, findsNothing);
    await finish(tester);
  });

  testWidgets('a narrow window folds the card into the menu button', (
    tester,
  ) async {
    await start(tester, 1240);
    await resize(tester, 900);
    expect(card, findsNothing);
    expect(menu, findsOneWidget);

    // The button brings it over the panel; a click beside it closes it.
    await tester.tap(menu);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(card, findsOneWidget);
    expect(find.byIcon(Icons.menu_open_rounded), findsOneWidget);
    await tester.tapAt(const Offset(700, 400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(card, findsNothing);

    // The tabs still work where the card was.
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('Search memories'), findsOneWidget);

    // Room again: back in its place, and the button goes.
    await resize(tester, 1240);
    expect(card, findsOneWidget);
    expect(menu, findsNothing);
    await finish(tester);
  });

  for (final still in [false, true]) {
    testWidgets('folding and unfolding keeps every tab as it was'
        '${still ? ' (reduced motion)' : ''}', (tester) async {
      if (still) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      await start(tester, 1240);
      await tester.tap(find.byIcon(Icons.image_outlined).first);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byIcon(Icons.chat_bubble_outline_rounded).first);
      await tester.pump(const Duration(seconds: 1));
      State<StatefulWidget> chat() =>
          tester.state(find.byType(ChatScreen, skipOffstage: false));
      State<StatefulWidget> images() =>
          tester.state(find.byType(ImagesScreen, skipOffstage: false));
      final chatBefore = chat();
      final imagesBefore = images();

      await resize(tester, 900);
      expect(menu, findsOneWidget);
      expect(identical(chat(), chatBefore), isTrue);
      expect(identical(images(), imagesBefore), isTrue);

      await resize(tester, 1240);
      expect(menu, findsNothing);
      expect(identical(chat(), chatBefore), isTrue);
      expect(identical(images(), imagesBefore), isTrue);
      await finish(tester);
    });
  }

  testWidgets('the shell lets go of every curve it makes', (tester) async {
    // Curves still alive, from what the framework reports in debug builds.
    final alive = <Object>{};
    void track(ObjectEvent event) {
      if (event.object is! CurvedAnimation) return;
      if (event is ObjectCreated) alive.add(event.object);
      if (event is ObjectDisposed) alive.remove(event.object);
    }

    FlutterMemoryAllocations.instance.addListener(track);
    addTearDown(() => FlutterMemoryAllocations.instance.removeListener(track));
    await start(tester, 1240);
    for (final width in [900.0, 1240.0, 1000.0, 1200.0]) {
      await resize(tester, width);
    }
    await finish(tester);
    expect(alive, isEmpty);
  });

  testWidgets('every tab fits the smallest window', (tester) async {
    await start(tester, 820);
    for (final icon in [
      Icons.image_outlined,
      Icons.auto_awesome_outlined,
      Icons.school_outlined,
      Icons.alarm_rounded,
      Icons.tune_rounded,
      Icons.chat_bubble_outline_rounded,
    ]) {
      await tester.tap(find.byIcon(icon).first);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    }
    await finish(tester);
  });

  testWidgets('folded, the LoRAs show only the picked ones', (tester) async {
    final picked = <String, double>{'b': 0.6};
    var open = false;
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(const Color(0xFF8B7CF6)),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => LoraSection(
              loras: const [
                (name: 'a', note: ''),
                (name: 'b', note: ''),
                (name: 'c', note: ''),
              ],
              picked: picked,
              open: open,
              onToggle: () => setState(() => open = !open),
              onChanged: (n, w) =>
                  setState(() => w == null ? picked.remove(n) : picked[n] = w),
            ),
          ),
        ),
      ),
    );
    expect(find.text('1 of 3 on'), findsOneWidget);
    expect(find.text('a'), findsNothing);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('Strength'), findsOneWidget);
    await tester.tap(find.text('LoRAs'));
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
    await tester.tap(find.text('c'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 on'), findsOneWidget);
  });
}
