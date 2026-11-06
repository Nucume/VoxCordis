import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/features/settings/settings_screen.dart';
import 'package:companion/features/voces/voces_home.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';
import 'package:companion/shell/companion_switcher.dart';
import 'package:companion/theme/app_theme.dart';

void main() {
  late Directory dir;
  late AppServices services;

  Future<void> setUpApp(WidgetTester tester, {required bool voces}) async {
    dir = Directory.systemTemp.createTempSync('voces_home');
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
            companionName: 'Voxette',
            companionFolder: p.join(dir.path, 'VoxCordis', 'Voxette'),
            vocesMundi: voces,
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
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          home: Scaffold(
            body: CompanionSwitcher(
              chat: ChatController(services),
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

  testWidgets('the menu shows Voces Mundi only when it is switched on', (
    tester,
  ) async {
    await setUpApp(tester, voces: false);
    await openMenu(tester);
    expect(find.text('Voces Mundi'), findsNothing);
  });

  testWidgets('Voces Mundi in the menu opens it', (tester) async {
    await setUpApp(tester, voces: true);
    await openMenu(tester);
    expect(find.text('RPG mode · Worlds, stories, lorebooks'), findsOneWidget);
    await tester.tap(find.text('Voces Mundi'));
    await tester.pumpAndSettle();
    expect(services.vocesOpen.value, isTrue);
  });

  testWidgets('home: worlds, characters, lorebooks and search', (tester) async {
    await setUpApp(tester, voces: true);
    final lib = VocesLibrary.inside(p.join(dir.path, 'VoxCordis'));
    await tester.runAsync(() async {
      final mira = await lib.saveCharacter(
        const VocesCharacter(
          id: '',
          name: 'Mira',
          line: 'Smuggler captain',
          sections: [SheetSection('Who they are', 'Runs the Lantern Run.')],
        ),
      );
      final book = await lib.saveLorebook(
        const Lorebook(
          id: '',
          name: 'Ember lore',
          entries: [
            LoreEntry(
              title: 'The lighthouse',
              keys: ['lighthouse'],
              text: 'Never dark.',
            ),
            LoreEntry(title: 'The Crown', keys: ['crown'], text: 'Taxes all.'),
          ],
        ),
      );
      // Hidden while Mature content is off.
      await lib.saveWorld(
        const VocesWorld(id: '', name: 'Iron Saints', adult: true),
      );
      await lib.saveWorld(
        VocesWorld(
          id: '',
          name: 'Ember Coast',
          line: 'A smugglers\' harbour',
          tags: const ['Fantasy'],
          castIds: [mira.id],
          lorebookIds: [book.id],
        ),
      );
    });
    services.vocesOpen.value = true;
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: AppTheme.dark(const Color(0xFFC9B8FF)),
          home: const VocesHome(),
        ),
      ),
    );
    // The library loads from disk, outside the test's fake clock.
    for (
      var i = 0;
      i < 200 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('Ember Coast'), findsOneWidget);
    expect(find.text('Iron Saints'), findsNothing);
    expect(
      find.textContaining('Stories you start show up here'),
      findsOneWidget,
    );

    // A world's page lists its cast and lorebooks.
    await tester.tap(find.text('Ember Coast'));
    await tester.pumpAndSettle();
    expect(find.text('Start a story'), findsOneWidget);
    expect(find.text('Mira'), findsOneWidget);
    expect(find.text('Ember lore'), findsOneWidget);

    // The cast opens the character's sheet.
    await tester.tap(find.text('Mira'));
    await tester.pumpAndSettle();
    expect(find.text('Runs the Lantern Run.'), findsOneWidget);
    expect(
      find.text('Ember Coast'),
      findsWidgets,
    ); // filter pill and "In worlds"

    // Lorebooks light up what a line would call up.
    await tester.tap(find.text('Lorebooks'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'e.g. Is the lighthouse lit tonight?'),
      'Is the lighthouse lit?',
    );
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 would come in.'), findsOneWidget);

    // Search reaches every kind.
    await tester.enterText(
      find.widgetWithText(TextField, 'Search everything'),
      'crown',
    );
    await tester.pumpAndSettle();
    expect(find.text('Results for “crown”'), findsOneWidget);
    expect(find.text('The Crown'), findsOneWidget);

    // A new world gets its own colours, an upload, or a drawing.
    await tester.enterText(
      find.widgetWithText(TextField, 'Search everything'),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New world').first);
    await tester.pumpAndSettle();
    expect(find.text('Shuffle colours'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
    await tester.ensureVisible(find.text('Draw it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Drawing is switched off'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    // Typed work isn't lost: Cancel asks, and going elsewhere keeps a
    // draft.
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    final draft = File(p.join(lib.draftsFolder, 'world-new.json'));
    await tester.tap(find.text('New world').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Moonwell');
    await tester.pump();
    expect(find.text('Moonwell'), findsWidgets); // field and preview
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Keep this as a draft?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Moonwell'), findsWidgets);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await settle();
    expect(find.text('Moonwell'), findsNothing);
    expect(draft.existsSync(), isFalse);

    await tester.tap(find.text('New world').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Driftwood');
    await tester.pump();
    await tester.tap(find.text('Lorebooks'));
    await settle();
    expect(find.text('Driftwood'), findsNothing);
    expect(draft.existsSync(), isTrue);
    await tester.tap(find.text('New world').first);
    await tester.pumpAndSettle();
    expect(find.text('Driftwood'), findsWidgets);
    expect(find.text('Discard draft'), findsOneWidget);
    await tester.tap(find.text('Discard draft'));
    await settle();
    expect(find.text('Driftwood'), findsNothing);
    expect(draft.existsSync(), isFalse);
    // Nothing typed: Cancel just closes.
    await tester.tap(find.text('Cancel').last);
    await settle();
    expect(find.text('Keep this as a draft?'), findsNothing);
    expect(find.text('Describe it'), findsNothing);

    // A lore entry opens as a page too; Esc leaves it.
    await tester.tap(find.text('Lorebooks'));
    await settle();
    await tester.tap(find.text('The lighthouse'));
    await settle();
    expect(find.text('When it comes in'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(find.text('When it comes in'), findsNothing);

    // Ctrl+S saves.
    await tester.tap(find.text('New world').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Saltmarsh');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Saving writes files, outside the test's fake clock.
    for (
      var i = 0;
      i < 100 && find.text('Create world').evaluate().isNotEmpty;
      i++
    ) {
      await settle();
    }
    expect(find.text('Start a story'), findsOneWidget); // its page
    expect(find.text('Saltmarsh'), findsWidgets);

    // Settings open in the main panel, and the tabs lead back.
    await tester.tap(find.text('Settings'));
    await settle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.text('Worlds'));
    await settle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Ember Coast'), findsOneWidget);

    // Back to the companion.
    await tester.tap(find.text('Back to Voxette'));
    await tester.pump();
    expect(services.vocesOpen.value, isFalse);
  });

  testWidgets('a story starts from a world and opens in the main panel', (
    tester,
  ) async {
    await setUpApp(tester, voces: true);
    final lib = VocesLibrary.inside(p.join(dir.path, 'VoxCordis'));
    await tester.runAsync(() async {
      final mira = await lib.saveCharacter(
        const VocesCharacter(id: '', name: 'Mira', line: 'Smuggler captain'),
      );
      await lib.saveCharacter(
        const VocesCharacter(id: '', name: 'Haru', line: 'A stranger'),
      );
      await lib.saveWorld(
        VocesWorld(
          id: '',
          name: 'Ember Coast',
          castIds: [mira.id],
          openings: const [
            Opening(
              'Off the boat',
              'Place: The rainy quay\nRain drums on the planks as you step ashore.',
            ),
          ],
        ),
      );
    });
    services.vocesOpen.value = true;
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: AppTheme.dark(const Color(0xFFC9B8FF)),
          home: const VocesHome(),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
      }
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await settle();
      }
    }

    await until(
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await tester.tap(find.text('Ember Coast'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start a story'));
    await tester.pumpAndSettle();
    expect(find.text('A new story in Ember Coast'), findsOneWidget);
    // Someone outside the world's cast is picked to play.
    expect(find.textContaining('Haru · A stranger'), findsOneWidget);
    expect(find.text('Grimdark'), findsNothing); // not an 18+ world
    await tester.tap(find.text('Begin'));
    await until(() => find.text('Haru (you)').evaluate().isNotEmpty);

    expect(find.textContaining('Rain drums on the planks'), findsOneWidget);
    expect(find.text('The rainy quay'), findsOneWidget); // where
    expect(find.text('Haru (you)'), findsOneWidget);
    expect(find.text('Mira'), findsOneWidget); // here at the start
    expect(find.text('Say'), findsOneWidget);
    expect(find.text('Ask the narrator'), findsOneWidget);

    // Bringing someone in or sending them off shows as a divider.
    await tester.tap(find.byTooltip('More about Mira'));
    await tester.pumpAndSettle();
    expect(find.text('Save to Characters'), findsOneWidget);
    await tester.tap(find.text('Send them off'));
    await until(() => find.text('Mira leaves').evaluate().isNotEmpty);
    expect(find.text('Mira leaves'), findsOneWidget);

    // Back, and the story is under Continue.
    await tester.tap(find.byTooltip('Back to the worlds'));
    await until(() => find.text('Haru in Ember Coast').evaluate().isNotEmpty);
    expect(find.text('Haru in Ember Coast'), findsWidgets);
    expect(
      File(services.storyDbPath('haru-in-ember-coast')).existsSync(),
      isTrue,
    );
  });
}
