import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';
import 'package:companion/shell/companion_switcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const first = AppSettings(
    companionName: 'Aria',
    pronouns: 'she/her',
    traits: ['warm'],
    companionFolder: '/home/x/VoxCordis/Aria',
    accentColor: 0xFFFF7AB6,
    backgroundColors: [1, 2],
    backgroundLayout: 0.3,
    userName: 'Sam',
    modelPath: '/models/a.gguf',
    themeChoice: ThemeChoice.light,
  );
  const second = CompanionProfile(
    id: 'abc',
    name: 'Mira',
    folder: '/home/x/VoxCordis/Mira',
    pronouns: 'they/them',
    traits: ['curious'],
  );

  test('switching keeps the human and brain, and parks the companion', () {
    final s = first.copyWith(otherCompanions: [second]).switchedTo(second);
    expect(s.companionName, 'Mira');
    expect(s.companionId, 'abc');
    expect(s.companionFolder, second.folder);
    expect(s.accentColor, const AppSettings().accentColor);
    expect(s.backgroundColors, isEmpty);
    // Shared by every companion.
    expect(s.userName, 'Sam');
    expect(s.modelPath, '/models/a.gguf');
    expect(s.themeChoice, ThemeChoice.light);
    // The first companion waits, unchanged, among the others.
    expect(s.otherCompanions.map((c) => c.name), ['Aria']);
    final back = s.switchedTo(s.otherCompanions.single);
    expect(back.companionId, isNull);
    expect(back.companionName, 'Aria');
    expect(back.accentColor, 0xFFFF7AB6);
    expect(back.backgroundColors, [1, 2]);
    expect(back.backgroundLayout, 0.3);
    expect(back.otherCompanions.single.name, 'Mira');
    expect(back.companions.map((c) => c.name), ['Aria', 'Mira']);
  });

  test('companions and the notice survive a save', () {
    final s = first
        .copyWith(otherCompanions: [second], toldAboutMoreCompanions: true)
        .switchedTo(second);
    final read = AppSettings.fromJson(
      jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>,
    );
    expect(read.companionId, 'abc');
    expect(read.toldAboutMoreCompanions, isTrue);
    final j = read.otherCompanions.single;
    expect(j.name, 'Aria');
    expect(j.id, isNull);
    expect(j.traits, ['warm']);
    expect(j.backgroundLayout, 0.3);
    // Older settings files have neither.
    final old = AppSettings.fromJson({'companionName': 'X'});
    expect(old.otherCompanions, isEmpty);
    expect(old.toldAboutMoreCompanions, isFalse);
  });

  test('each companion keeps its own chats', () async {
    final tmp = await Directory.systemTemp.createTemp('companions_test');
    addTearDown(() => tmp.delete(recursive: true));
    final start = first.copyWith(
      companionFolder: p.join(tmp.path, 'Aria'),
      llmMode: LlmMode.external,
      llmModel: 'mock',
    );
    final runtime = RuntimeController(tmp);
    final key = DatabaseKey(
      tmp,
      secrets: SecretStore(
        Directory(p.join(tmp.path, 'secrets')),
        system: false,
      ),
    );
    await key.unlock();
    final services = AppServices(
      settings: SettingsStore(File(p.join(tmp.path, 'settings.json')), start),
      db: await openAppDatabase(
        AppServices.companionDbPath(tmp.path, null),
        key: key.value,
      ),
      runtime: runtime,
      dbKey: key,
    );
    await services.messages.add('user', 'hello Aria');

    final mira = CompanionProfile(
      id: 'mira-id',
      name: 'Mira',
      folder: p.join(tmp.path, 'Mira'),
    );
    await services.switchCompanion(services.settings.value.switchedTo(mira));
    expect(services.settings.value.companionName, 'Mira');
    expect(await services.messages.recent(), isEmpty);
    expect(
      File(p.join(tmp.path, 'companions', 'mira-id.db')).existsSync(),
      isTrue,
    );
    await services.messages.add('user', 'hello Mira');

    await services.switchCompanion(
      services.settings.value.switchedTo(
        services.settings.value.otherCompanions.single,
      ),
    );
    expect(services.settings.value.companionId, isNull);
    expect((await services.messages.recent()).map((m) => m.content), [
      'hello Aria',
    ]);

    // Both are encrypted, and a new key reaches both, the open one too.
    expect(key.databases(), hasLength(2));
    expect(key.databases().every((f) => !DatabaseKey.isPlain(f)), isTrue);
    await services.changeDatabaseKey('a new password');
    await services.messages.add('user', 'still here');
    for (final f in key.databases()) {
      expect(DatabaseKey.opens(f, 'a new password'), isTrue);
    }
    await services.db.close();
  });

  test('the menu lists what fits and puts the rest behind More', () {
    // Plenty of room: everyone.
    expect(CompanionSwitcher.fitting(3, 800), 3);
    // Room for four rows: three companions and "More…".
    expect(CompanionSwitcher.fitting(9, 184 + 4 * 60.0), 3);
    // A tiny window still lists the current companion.
    expect(CompanionSwitcher.fitting(9, 100), 1);
  });
}
