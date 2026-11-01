import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;

import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/locked_chats.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  late Directory dir;
  late SecretStore secrets;

  DatabaseKey keyFor() => DatabaseKey(dir, secrets: secrets);
  String first() => p.join(dir.path, 'companion.db');

  Future<void> write(String path, List<String> texts, String key) async {
    await Directory(p.dirname(path)).create(recursive: true);
    final db = await openAppDatabase(path, key: key);
    var order = 0;
    final had = await db.rawQuery(
      'SELECT coalesce(max(sort_order), 0) AS n FROM messages',
    );
    order = had.first['n'] as int;
    for (final t in texts) {
      await db.insert('messages', {
        'id': '$t-${order + 1}',
        'ts': '2026-10-26T10:00:00Z',
        'role': 'user',
        'content': t,
        'sort_order': ++order,
      });
    }
    await db.close();
  }

  Future<List<String>> read(String path, String key) async {
    final db = await openAppDatabase(path, key: key);
    final rows = await db.query('messages', orderBy: 'sort_order');
    await db.close();
    return [for (final r in rows) r['content'] as String];
  }

  /// [path] as the app leaves it when killed mid-write: the change half
  /// done in the file, the journal to undo it still there ("hot").
  void leaveHalfWritten(String path, String key) {
    final copyDir = Directory(p.join(dir.path, 'half'))..createSync();
    final copy = p.join(copyDir.path, 'companion.db');
    final db = raw.sqlite3.open(path);
    db.execute('PRAGMA key = ${DatabaseKey.quote(key)}');
    db.execute('PRAGMA cache_size = 2');
    db.execute('BEGIN');
    db.execute("UPDATE messages SET content = content || 'changed'");
    File(path).copySync(copy);
    File('$path-journal').copySync('$copy-journal');
    db.execute('ROLLBACK');
    db.close();
    File(copy).copySync(path);
    File('$copy-journal').copySync('$path-journal');
    copyDir.deleteSync(recursive: true);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('locked');
    secrets = SecretStore(
      Directory(p.join(dir.path, 'secrets')),
      system: false,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a database left half-written still opens with its key', () async {
    final key = keyFor();
    await key.unlock();
    final texts = [for (var i = 0; i < 400; i++) 'message $i ${'x' * 900}'];
    await write(first(), texts, key.value);
    leaveHalfWritten(first(), key.value);
    expect(File('${first()}-journal').existsSync(), isTrue);
    final before = File(first()).readAsBytesSync();

    // A wrong key is still told apart, and the real file isn't touched.
    expect(DatabaseKey.opens(File(first()), 'not the key'), isFalse);
    expect(File(first()).readAsBytesSync(), before);

    final again = keyFor();
    expect(await again.unlock(), isTrue);
    expect(await read(first(), again.value), texts);
  });

  test('starting over keeps the old key, and finds it again', () async {
    final key = keyFor();
    await key.unlock();
    final old = key.value;
    await write(first(), ['from before'], old);
    // The database looks unreadable (say, it was busy): start over.
    final lost = keyFor();
    final aside = await lost.setAside();
    expect(lost.value, isNot(old));
    expect(lost.lockedFolders().map((d) => d.path), [aside.path]);
    expect(await lost.keptKeyFor(aside), old);
  });

  test('a database a kept key opens unlocks by itself', () async {
    await secrets.write(DatabaseKey.secretName, 'the new key');
    await secrets.write(DatabaseKey.earlierName, '["the old key"]');
    await write(first(), ['hello'], 'the old key');
    final key = keyFor();
    expect(await key.unlock(), isTrue);
    expect(key.value, 'the old key');
    expect(await secrets.read(DatabaseKey.secretName), 'the old key');
  });

  test('set-aside chats come back before the new ones', () async {
    final key = keyFor();
    await key.unlock();
    final old = key.value;
    await write(first(), ['old one', 'old two'], old);
    final other = p.join(dir.path, 'companions', 'b.db');
    await write(other, ['other old'], old);
    final db0 = await openAppDatabase(first(), key: old);
    await db0.insert('memories', {
      'id': 'm1',
      'text': 'likes tea',
      'valid_from': '2026-10-01',
      'recorded_at': '2026-10-01',
    });
    await db0.insert('story', {
      'id': 1,
      'text': 'they met',
      'through': 1,
      'updated_at': '2026-10-01',
    });
    await db0.close();

    final lost = keyFor();
    final aside = await lost.setAside();
    await write(first(), ['new one'], lost.value);
    final open = await openAppDatabase(first(), key: lost.value);
    final n = await LockedChats(
      lost,
    ).bringBack(aside, old, open: open, openPath: first());
    expect(n, 3);
    final rows = await open.query('messages', orderBy: 'sort_order');
    expect(
      [for (final r in rows) r['content']],
      ['old one', 'old two', 'new one'],
    );
    expect((await open.query('memories')).map((r) => r['text']), ['likes tea']);
    expect((await open.query('story')).single['through'], 1);
    await open.close();
    expect(aside.existsSync(), isFalse);
    // The other companion had no new database: its own came back as is.
    expect(await read(other, lost.value), ['other old']);
    expect(lost.lockedFolders(), isEmpty);
  });

  test('a wrong key brings nothing back', () async {
    final key = keyFor();
    await key.unlock();
    await write(first(), ['old'], key.value);
    final lost = keyFor();
    final aside = await lost.setAside();
    await secrets.delete(DatabaseKey.earlierName);
    expect(await lost.keptKeyFor(aside), isNull);
    final open = await openAppDatabase(first(), key: lost.value);
    await expectLater(
      LockedChats(
        lost,
      ).bringBack(aside, 'wrong', open: open, openPath: first()),
      throwsStateError,
    );
    await open.close();
    expect(aside.existsSync(), isTrue);
  });
}
