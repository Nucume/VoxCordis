import 'dart:io';

import 'package:companion/services/changelog.dart';
import 'package:flutter_test/flutter_test.dart';

const _log = '''
# Changelog

Intro text.

## Unreleased
- Not out yet.

## 0.2.2 (2026-11-20)
### New
- Pictures.

## 0.2.1
- Encryption.
{{action:open-settings}}

## 0.2.0
- Companions.
''';

void main() {
  test('reads versions newest first, skips Unreleased, pulls out actions', () {
    final all = parseChangelog(_log);
    expect(all.map((e) => e.version), ['0.2.2', '0.2.1', '0.2.0']);
    expect(all[0].notes, '### New\n- Pictures.');
    expect(all[1].notes, '- Encryption.');
    expect(all[1].actions, ['open-settings']);
    expect(all[2].actions, isEmpty);
  });

  test('changes since covers every skipped version', () {
    final all = parseChangelog(_log);
    expect(changesSince(all, '0.2.0', '0.2.2').map((e) => e.version), [
      '0.2.2',
      '0.2.1',
    ]);
    expect(changesSince(all, '0.2.1', '0.2.2').map((e) => e.version), [
      '0.2.2',
    ]);
    expect(changesSince(all, '0.2.2', '0.2.2'), isEmpty);
  });

  group('pending', () {
    late Directory dir;
    late File file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('whats_new');
      file = File('${dir.path}/last_version');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<({String? from, List<ChangelogEntry> notes})> start(
      String version, {
      bool wasSetUp = true,
    }) => WhatsNew(
      file,
      current: version,
    ).pending(wasSetUp: wasSetUp, readChangelog: () async => _log);

    test('a fresh install shows nothing and remembers its version', () async {
      final r = await start('0.2.1', wasSetUp: false);
      expect(r.notes, isEmpty);
      expect(file.readAsStringSync(), '0.2.1');
      expect((await start('0.2.2')).notes.map((e) => e.version), ['0.2.2']);
    });

    test('an install from before tracking counts as 0.2.0', () async {
      final r = await start('0.2.2');
      expect(r.from, '0.2.0');
      expect(r.notes.map((e) => e.version), ['0.2.2', '0.2.1']);
    });

    test('shows once, and not after a downgrade', () async {
      file.writeAsStringSync('0.2.1');
      expect((await start('0.2.2')).notes, hasLength(1));
      expect((await start('0.2.2')).notes, isEmpty);
      expect((await start('0.2.1')).notes, isEmpty);
      expect(file.readAsStringSync(), '0.2.1');
    });

    test('a broken changelog never stops the start', () async {
      file.writeAsStringSync('0.2.0');
      final r = await WhatsNew(
        file,
        current: '0.2.1',
      ).pending(wasSetUp: true, readChangelog: () async => throw 'missing');
      expect(r.notes, isEmpty);
      expect(file.readAsStringSync(), '0.2.1');
    });
  });

  test('the bundled CHANGELOG.md parses', () {
    final all = parseChangelog(File('CHANGELOG.md').readAsStringSync());
    expect(all.map((e) => e.version), contains('0.2.0'));
    expect(all.every((e) => e.notes.isNotEmpty), isTrue);
  });
}
