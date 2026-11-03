import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/settings_screen.dart';
import 'package:companion/services/runtime/gpu_info.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

/// Downloads finish when the test says so.
class _SlowRuntime extends RuntimeController {
  _SlowRuntime(super.supportDir);

  final done = Completer<String>();
  CatalogModel? model;

  @override
  Future<GpuInfo> get gpu async => GpuInfo.unknown;

  @override
  Future<String> download(CatalogModel m, Directory modelsDir) {
    model = m;
    downloads[m.id] = null;
    notifyListeners();
    return done.future.whenComplete(() {
      downloads.remove(m.id);
      notifyListeners();
    });
  }
}

void main() {
  late Directory dir;
  late AppServices services;
  late _SlowRuntime runtime;
  final page = GlobalKey<SettingsScreenState>();

  /// Settings open on Brain, with a download started there.
  Future<void> startDownload(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    dir = Directory.systemTemp.createTempSync('settings_download');
    addTearDown(() => dir.deleteSync(recursive: true));
    runtime = _SlowRuntime(dir);
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
            companionName: 'Aria',
            userName: 'Sam',
            modelsFolder: p.join(dir.path, 'models'),
            modelPath: '/old.gguf',
            contextSize: 16384,
            useGpu: false,
          ),
        ),
        db: await openAppDatabase(
          AppServices.companionDbPath(dir.path, null),
          key: key.value,
        ),
        runtime: runtime,
        dbKey: key,
      );
    });
    addTearDown(() => tester.runAsync(services.db.close));

    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              key: page,
              initialTab: SettingsScreen.brainTab,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Download').first);
    await tester.pump();
    expect(runtime.model, isNotNull);
  }

  testWidgets('a download finished on another Settings page is chosen', (
    tester,
  ) async {
    await startDownload(tester);

    // Another page, and a change there, while it downloads.
    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Sammy');

    final path = ModelCatalog.fileFor(
      Directory(p.join(dir.path, 'models')),
      runtime.model!,
    ).path;
    runtime.done.complete(path);
    await settle(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      // Saved once the name is in the file.
      final file = File(p.join(dir.path, 'settings.json'));
      for (var i = 0; i < 100; i++) {
        if (file.existsSync() && file.readAsStringSync().contains('Sammy')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    final s = services.settings.value;
    expect(s.modelPath, path);
    // Sized for it, as picking it would: on the processor that is 8k.
    expect(s.contextSize, 8192);
    expect(s.userName, 'Sammy');
  });

  testWidgets('a download finished after Settings closed changes nothing', (
    tester,
  ) async {
    await startDownload(tester);
    await tester.pumpWidget(const SizedBox());

    runtime.done.complete('/new.gguf');
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(services.settings.value.modelPath, '/old.gguf');
  });
}

/// Lets file reads finish, a few rounds deep.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}
