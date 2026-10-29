import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/images/images_screen.dart';
import 'package:companion/features/images/resizable_field.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  test('the draw panel prefs survive a trip through settings.json', () {
    final prefs = const DrawPanelPrefs(advanced: true, shape: 'portrait')
        .copyWith(model: 'anima')
        .withChoices(
          'anima',
          const DrawChoices(
            width: 768,
            height: 1024,
            steps: 30,
            cfg: 4,
            seed: 7,
            negative: 'blurry',
          ),
        )
        .withChoices('sdxl', const DrawChoices(steps: 12));
    final back = AppSettings.fromJson(
      AppSettings(draw: prefs).toJson().map((k, v) => MapEntry(k, v)),
    ).draw;
    expect(back.advanced, isTrue);
    expect(back.shape, 'portrait');
    expect(back.model, 'anima');
    expect(back.perModel['anima'], prefs.perModel['anima']);
    expect(back.perModel['sdxl']?.steps, 12);
    expect(back.perModel['sdxl']?.width, isNull);
    // Back to nothing set drops the entry.
    expect(back.withChoices('sdxl', const DrawChoices()).perModel.keys, [
      'anima',
    ]);
  });

  test('old or broken settings give the plain panel', () {
    expect(AppSettings.fromJson(const {}).draw.advanced, isFalse);
    final odd = DrawPanelPrefs.fromJson({
      'shape': 'diagonal',
      'perModel': {'a': 3, 'b': <String, Object?>{}},
    });
    expect(odd.shape, 'square');
    expect(odd.perModel.keys, ['b']);
  });

  testWidgets('dragging the grip resizes the field, double tap undoes it', (
    tester,
  ) async {
    final c = TextEditingController(text: 'hello');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 400, child: ResizableField(controller: c)),
            ),
          ),
        ),
      ),
    );
    final before = tester.getSize(find.byType(ResizableField)).height;
    await tester.drag(
      find.byKey(const ValueKey('resize-grip')),
      const Offset(0, 150),
    );
    await tester.pump();
    final after = tester.getSize(find.byType(ResizableField)).height;
    expect(after, closeTo(before + 150, 1));
    // Not smaller than a line.
    await tester.drag(
      find.byKey(const ValueKey('resize-grip')),
      const Offset(0, -900),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(ResizableField)).height, 56);
    await tester.tap(find.byKey(const ValueKey('resize-grip')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('resize-grip')));
    await tester.pump();
    expect(tester.getSize(find.byType(ResizableField)).height, before);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the panel comes back as it was left, per model', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('draw_panel');
    addTearDown(() => dir.deleteSync(recursive: true));
    final images = Directory(p.join(dir.path, 'models', 'images'))
      ..createSync(recursive: true);
    File(p.join(images.path, 'alpha.safetensors')).writeAsBytesSync([1]);
    File(p.join(images.path, 'beta.safetensors')).writeAsBytesSync([1]);
    final file = File(p.join(dir.path, 'settings.json'));
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
          file,
          AppSettings(
            companionName: 'Aria',
            companionFolder: p.join(dir.path, 'Aria'),
            imageEngine: ImageEngineChoice.builtIn,
            modelsFolder: p.join(dir.path, 'models'),
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

    Future<void> show() async {
      await tester.pumpWidget(
        AppScope(
          services: services,
          child: MaterialApp(
            home: Scaffold(body: ImagesScreen(key: UniqueKey())),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }

    Finder field(String label) => find.descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextField),
    );

    await show();
    await tester.tap(find.text('Draw').first);
    await tester.pumpAndSettle();
    expect(find.text('Steps'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Steps'), findsOneWidget);
    await tester.enterText(field('Steps'), '17');
    await tester.enterText(field('Seed'), '99');
    await tester.pump(const Duration(seconds: 1));

    // Another model starts clean...
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('beta').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('Steps')).controller!.text, '');
    await tester.enterText(field('Steps'), '5');
    await tester.pump(const Duration(seconds: 1));

    // ...and each gets its own back after a restart.
    await tester.pumpWidget(const SizedBox());
    await show();
    await tester.tap(find.text('Draw').first);
    await tester.pumpAndSettle();
    expect(find.text('Steps'), findsOneWidget);
    expect(tester.widget<TextField>(field('Steps')).controller!.text, '5');
    await tester.tap(find.text('beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('alpha').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('Steps')).controller!.text, '17');
    expect(tester.widget<TextField>(field('Seed')).controller!.text, '99');
    expect(services.settings.value.draw.advanced, isTrue);
  });
}
