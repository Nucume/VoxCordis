import 'dart:convert';
import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:companion/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('secrets'));
  tearDown(() => tmp.delete(recursive: true));

  SecretStore fileOnly() =>
      SecretStore(Directory(p.join(tmp.path, 'secrets')), system: false);

  test('the API key never lands in settings.json', () async {
    final store = await SettingsStore.load(tmp, secrets: fileOnly());
    await store.update(store.value.copyWith(llmApiKey: 'sk-test-123'));
    final json = await File(p.join(tmp.path, 'settings.json')).readAsString();
    expect(json, isNot(contains('sk-test-123')));
    expect(jsonDecode(json), isNot(contains('llmApiKey')));

    final again = await SettingsStore.load(tmp, secrets: fileOnly());
    expect(again.value.llmApiKey, 'sk-test-123');
  });

  test('a key from an older settings.json is moved out', () async {
    final file = File(p.join(tmp.path, 'settings.json'));
    await file.writeAsString(
      jsonEncode({
        'llmMode': 'external',
        'llmModel': 'm',
        'llmApiKey': 'sk-old-key',
      }),
    );
    final store = await SettingsStore.load(tmp, secrets: fileOnly());
    expect(store.value.llmApiKey, 'sk-old-key');
    expect(await file.readAsString(), isNot(contains('sk-old-key')));
    expect(await fileOnly().read(SettingsStore.apiKeySecret), 'sk-old-key');
  });

  test('clearing the key forgets it', () async {
    final store = await SettingsStore.load(tmp, secrets: fileOnly());
    await store.update(store.value.copyWith(llmApiKey: 'k'));
    await store.update(store.value.copyWith(llmApiKey: ''));
    expect(await fileOnly().read(SettingsStore.apiKeySecret), isNull);
  });

  test('files are private to the user', () async {
    final store = await SettingsStore.load(tmp, secrets: fileOnly());
    await store.update(store.value.copyWith(llmApiKey: 'k'));
    String mode(String path) =>
        (FileStat.statSync(path).mode & 0x1FF).toRadixString(8);
    expect(mode(p.join(tmp.path, 'settings.json')), '600');
    expect(mode(p.join(tmp.path, 'secrets')), '700');
    expect(
      mode(p.join(tmp.path, 'secrets', SettingsStore.apiKeySecret)),
      '600',
    );
  }, skip: Platform.isWindows);

  // Runs against a real keyring when one is up, e.g. under
  // `dbus-run-session` with gnome-keyring unlocked; otherwise libsecret
  // reports an error and the store falls back to its file.
  test('libsecret round trip, or the file when no keyring runs', () async {
    final store = SecretStore(
      Directory(p.join(tmp.path, 'secrets')),
      backend: SecretBackend.libsecret(
        schema: 'io.github.nucume.VoxCordis.test',
      ),
    );
    await store.write('k', 'value-1');
    expect(await store.read('k'), 'value-1');
    final inFile = File(p.join(tmp.path, 'secrets', 'k')).existsSync();
    if (Platform.environment['EXPECT_KEYRING'] == '1') expect(inFile, isFalse);
    await store.delete('k');
    expect(await store.read('k'), isNull);
  }, skip: !Platform.isLinux);
}
