import 'package:companion/data/database.dart';
import 'package:companion/services/logs/app_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  var on = true;
  var off = <LogKind>{};
  late AppLog log;

  setUp(() async {
    db = await openAppDatabase(inMemoryDatabasePath);
    on = true;
    off = {};
    log = AppLog(
      db: () => db,
      enabled: (kind) => on && !off.contains(kind),
      secrets: () => ['my-own-search-key-123'],
    );
  });
  tearDown(() => db.close());

  test('keeps lines newest first, filtered by kind and failures', () async {
    log.add(LogKind.browser, 'Starting chrome');
    log.add(LogKind.web, 'Searched "tea"', details: 'a\nb');
    log.add(LogKind.browser, 'The page crashed', error: true);
    final all = await log.entries();
    expect(all.map((e) => e.message), [
      'The page crashed',
      'Searched "tea"',
      'Starting chrome',
    ]);
    expect((await log.entries(kinds: {LogKind.web})).single.details, 'a\nb');
    expect(
      (await log.entries(errorsOnly: true)).single.message,
      'The page crashed',
    );
    final text = await log.asText();
    expect(text.indexOf('Starting chrome'), lessThan(text.indexOf('crashed')));
    expect(text, contains('ERROR'));
    expect(text, contains('    a\n    b'));

    await log.clear();
    expect(await log.entries(), isEmpty);
  });

  test('writes nothing while off, and only the kinds turned on', () async {
    on = false;
    log.add(LogKind.chat, 'Replied');
    expect(await log.entries(), isEmpty);
    on = true;
    off = {LogKind.thinking};
    log.add(LogKind.thinking, 'Thoughts');
    log.add(LogKind.chat, 'Replied');
    expect((await log.entries()).single.message, 'Replied');
  });

  test('keeps the total size in bounds', () async {
    final big = 'x' * 100000;
    for (var i = 0; i < 100; i++) {
      await db.insert('logs', {
        'ts': DateTime.now().toUtc().toIso8601String(),
        'kind': 'thinking',
        'message': 'line $i',
        'details': big,
      });
    }
    await AppLog.trim(db);
    final rows = await db.query('logs', orderBy: 'id');
    expect(rows.length * big.length, lessThanOrEqualTo(AppLog.maxChars));
    expect(rows.last['message'], 'line 99');
  });

  test('blanks out keys and passwords', () async {
    log.add(
      LogKind.web,
      'GET https://api.example.com/?q=tea&api_key=abcdef123456 '
      'with my-own-search-key-123',
      details:
          'Authorization: Bearer sk-or-v1-0123456789abcdef0123\n'
          '{"apiKey": "zzz-secret-zzz", "password": "hunter22"}\n'
          'tvly-dev-ABCDEFGHIJKLMNOP and max_tokens=512',
    );
    final e = (await log.entries()).single;
    expect(e.message, isNot(contains('abcdef123456')));
    expect(e.message, isNot(contains('my-own-search-key-123')));
    expect(e.message, contains('q=tea'));
    for (final secret in [
      'sk-or-v1',
      'zzz-secret-zzz',
      'hunter22',
      'ABCDEFGHIJKLMNOP',
    ]) {
      expect(e.details, isNot(contains(secret)));
    }
    expect(e.details, contains('max_tokens=512'));
  });

  test('drops old lines and keeps the newest', () async {
    final old = DateTime.now().toUtc().subtract(const Duration(days: 8));
    await db.insert('logs', {
      'ts': old.toIso8601String(),
      'kind': 'web',
      'message': 'old',
    });
    for (var i = 0; i < AppLog.maxLines + 3; i++) {
      await db.insert('logs', {
        'ts': DateTime.now().toUtc().toIso8601String(),
        'kind': 'web',
        'message': 'line $i',
      });
    }
    await AppLog.trim(db);
    final rows = await db.query('logs', orderBy: 'id');
    expect(rows.length, AppLog.maxLines);
    expect(rows.first['message'], 'line 3');
  });
}
