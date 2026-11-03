import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/settings_screen.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';

/// Every field away from its default, so a lost one shows.
const _everything = AppSettings(
  companionName: 'Aria',
  pronouns: 'he/him',
  traits: ['bold'],
  userName: 'Sam',
  userPronouns: 'they/them',
  portraitPath: '/p.png',
  companionFolder: '/home/aria',
  llmMode: LlmMode.external,
  modelPath: '/m.gguf',
  modelsFolder: '/models',
  contextSize: 16384,
  useGpu: false,
  freeGpuWhenIdle: true,
  chatFormat: 'chatml',
  mmprojPath: '/mm.gguf',
  temperature: 0.7,
  llmEndpoint: 'http://x/v1',
  llmModel: 'm',
  invokeUrl: 'http://i',
  accentColor: 0xFF123456,
  backgroundColors: [1, 2],
  backgroundLayout: 0.4,
  colorway: 'haru',
  themeChoice: ThemeChoice.light,
  statusLight: StatusLight.header,
  settingsTabs: SettingsTabs.side,
  backgroundDim: 0.4,
  interfaceScale: 1.2,
  videoVolume: 30,
  playVideoPortraits: false,
  showNsfwAvatar: true,
  systemAccess: true,
  allowedSystemActions: ['run: ls'],
  allowEverything: true,
  companionId: 'abc',
  otherCompanions: [CompanionProfile(id: 'b', name: 'Bea', folder: '/bea')],
  toldAboutMoreCompanions: true,
  picturesToServerOk: true,
  internetAccess: true,
  companionBrowser: true,
  searchProvider: SearchProvider.searxng,
  searxngUrl: 'https://s',
  blockedSites: ['a.com'],
  keepRunning: true,
  keepLogs: false,
  logsOff: ['web'],
  startMode: StartMode.onScreen,
  automationRunsPerDay: 5,
  imageEngine: ImageEngineChoice.invoke,
  imageModel: 'sdxl',
  freeGpuForDrawing: false,
  draw: DrawPanelPrefs(perModel: {'sdxl': DrawChoices(steps: 12)}),
  pokeAfterHours: 6,
  pokeQuietFrom: 21,
  pokeQuietUntil: 9,
  pokeRepeat: true,
);

void main() {
  test('every setting survives settings.json', () {
    final json = jsonEncode(_everything.toJson());
    final back = AppSettings.fromJson(jsonDecode(json) as Map<String, Object?>);
    expect(jsonEncode(back.toJson()), json);
    // The defaults would hide a field toJson forgot.
    expect(json, isNot(jsonEncode(const AppSettings().toJson())));
    for (final entry in const AppSettings().toJson().entries) {
      if (entry.key == 'llmMode') continue; // follows llmModel when missing
      expect(
        jsonEncode(back.toJson()[entry.key]),
        isNot(jsonEncode(entry.value)),
        reason: '${entry.key} is still its default',
      );
    }
  });

  testWidgets('Save keeps what changed elsewhere while Settings was open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('settings_merge');
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
          const AppSettings(
            companionName: 'Aria',
            userName: 'Sam',
            llmMode: LlmMode.external,
            llmModel: 'm',
            useGpu: false,
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

    final page = GlobalKey<SettingsScreenState>();
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          home: Scaffold(body: SettingsScreen(key: page)),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    // Changed elsewhere while the page is open: in Pictures, in the chat,
    // by the companion, or by moving the models.
    final store = services.settings;
    await tester.runAsync(
      () => store.update(
        store.value.copyWith(
          videoVolume: 25,
          picturesToServerOk: true,
          draw: const DrawPanelPrefs(perModel: {'x': DrawChoices(steps: 9)}),
          modelsFolder: '/moved',
          modelPath: '/moved/m.gguf',
          accentColor: 0xFF00FF00,
          themeChoice: ThemeChoice.dark,
          settingsTabs: SettingsTabs.side,
        ),
      ),
    );
    await tester.pump();
    // Nothing was changed on the page itself.
    expect(page.currentState!.changed, isFalse);

    // Changed on the page.
    await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Sammy');
    expect(page.currentState!.changed, isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    final s = store.value;
    expect(s.userName, 'Sammy');
    expect(s.videoVolume, 25);
    expect(s.picturesToServerOk, isTrue);
    expect(s.draw.perModel['x']?.steps, 9);
    expect(s.modelsFolder, '/moved');
    expect(s.modelPath, '/moved/m.gguf');
    expect(s.accentColor, 0xFF00FF00);
    expect(s.themeChoice, ThemeChoice.dark);
    expect(s.settingsTabs, SettingsTabs.side);
    expect(page.currentState!.changed, isFalse);
  });
}
