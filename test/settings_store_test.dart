import 'dart:convert';
import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings_store');
    file = File(p.join(dir.path, 'settings.json'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> saved() =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  test('a burst of changes is written once, with the last of them', () async {
    final store = SettingsStore(file, const AppSettings());
    final saves = [
      for (var i = 1; i <= 20; i++)
        store.update(store.value.copyWith(interfaceScale: 1 + i / 100)),
    ];
    await Future.wait(saves);
    expect(store.writes, 1);
    expect(saved()['interfaceScale'], 1.2);
  });

  test('changes made while a save runs share the next one', () async {
    final store = SettingsStore(file, const AppSettings());
    final first = store.update(store.value.copyWith(companionName: 'One'));
    // Let the first save start, then change things under it.
    await Future<void>.delayed(Duration.zero);
    final later = [
      for (final name in ['Two', 'Three', 'Four'])
        store.update(store.value.copyWith(companionName: name)),
    ];
    await first;
    await Future.wait(later);
    expect(store.writes, 2);
    expect(saved()['companionName'], 'Four');
  });

  test('a change after a finished save is saved on its own', () async {
    final store = SettingsStore(file, const AppSettings());
    await store.update(store.value.copyWith(companionName: 'One'));
    expect(saved()['companionName'], 'One');
    await store.update(store.value.copyWith(companionName: 'Two'));
    expect(store.writes, 2);
    expect(saved()['companionName'], 'Two');
  });
}
