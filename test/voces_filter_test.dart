import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/data/voces/voces_library.dart';
import 'package:companion/data/voces/voces_models.dart';
import 'package:companion/features/voces/voces_home.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';
import 'package:companion/theme/app_theme.dart';
import 'package:companion/theme/glass_popover.dart';

/// The picker's own text: world names also show in a character's sheet.
Finder _picker(String text) => find.byWidgetPredicate(
  (w) => w is Text && w.data == text && w.style?.fontSize == 14,
);

void main() {
  testWidgets('a searchable picker narrows its options as you type', (
    tester,
  ) async {
    String? picked = 'none';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(const Color(0xFF8B7CF6)),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, set) => GlassSelect<String?>(
                value: null,
                searchHint: 'Search worlds',
                options: [
                  const GlassOption(null, 'All characters'),
                  for (final n in ['Ember Coast', 'Iron Saints', 'Palm Beach'])
                    GlassOption(n, n),
                ],
                onChanged: (v) => set(() => picked = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('All characters'));
    await tester.pumpAndSettle();
    expect(find.text('Iron Saints'), findsOneWidget);
    expect(find.text('Ember Coast'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search worlds'),
      'ir',
    );
    await tester.pumpAndSettle();
    expect(find.text('Iron Saints'), findsOneWidget);
    expect(find.text('Ember Coast'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search worlds'),
      'zz',
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search worlds'),
      'ir',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Iron Saints'));
    await tester.pumpAndSettle();
    expect(picked, 'Iron Saints');
  });

  testWidgets('Characters filters by world from one compact picker', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('voces_filter');
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
          AppSettings(
            companionName: 'Voxette',
            companionFolder: p.join(dir.path, 'VoxCordis', 'Voxette'),
            vocesMundi: true,
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
    final db = services.db;
    addTearDown(() => tester.runAsync(db.close));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final lib = VocesLibrary.inside(p.join(dir.path, 'VoxCordis'));
    await tester.runAsync(() async {
      final ids = <String>[];
      for (final n in ['Mira', 'Aurora', 'Chiara']) {
        ids.add((await lib.saveCharacter(VocesCharacter(id: '', name: n))).id);
      }
      for (var i = 0; i < 16; i++) {
        await lib.saveWorld(
          VocesWorld(
            id: '',
            name: 'World ${(i + 10).toRadixString(36)} number $i',
            // Mira is in the first world, Aurora in the last.
            castIds: [if (i == 0) ids[0], if (i == 15) ids[1]],
          ),
        );
      }
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

    await tester.tap(find.text('Characters'));
    await tester.pumpAndSettle();
    // One button, not a chip per world.
    expect(find.byType(GlassSelect<String?>), findsOneWidget);
    expect(find.text('World a number 0'), findsNothing);
    for (final n in ['Mira', 'Aurora', 'Chiara']) {
      expect(find.text(n), findsWidgets);
    }

    await tester.tap(find.text('All characters'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search worlds'),
      'number 15',
    );
    await tester.pumpAndSettle();
    await tester.tap(_picker('World p number 15'));
    await tester.pumpAndSettle();
    expect(find.text('Aurora'), findsWidgets);
    expect(find.text('Mira'), findsNothing);
    expect(find.text('Chiara'), findsNothing);

    // Back to everyone.
    await tester.tap(_picker('World p number 15'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All characters').last);
    await tester.pumpAndSettle();
    expect(find.text('Chiara'), findsWidgets);
  });
}
