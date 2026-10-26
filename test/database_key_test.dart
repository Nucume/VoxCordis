import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/services/secret_store.dart';

void main() {
  late Directory dir;
  late SecretStore secrets;

  DatabaseKey keyFor() => DatabaseKey(dir, secrets: secrets);
  String first() => p.join(dir.path, 'companion.db');
  String second() => p.join(dir.path, 'companions', 'b.db');

  Future<void> write(String path, String text, {String? key}) async {
    await Directory(p.dirname(path)).create(recursive: true);
    final db = await openAppDatabase(path, key: key);
    await db.insert('messages', {
      'id': text,
      'ts': '2026-10-26T10:00:00Z',
      'role': 'user',
      'content': text,
      'sort_order': 0,
    });
    await db.close();
  }

  Future<List<String>> read(String path, String key) async {
    final db = await openAppDatabase(path, key: key);
    final rows = await db.query('messages');
    await db.close();
    return [for (final r in rows) r['content'] as String];
  }

  bool onDiskInClear(String path, String text) =>
      String.fromCharCodes(File(path).readAsBytesSync()).contains(text);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dbkey');
    secrets = SecretStore(
      Directory(p.join(dir.path, 'secrets')),
      system: false,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a first start makes and keeps a random 64-character key', () async {
    final key = keyFor();
    expect(await key.unlock(), isTrue);
    expect(key.value, hasLength(64));
    expect(key.value, matches(RegExp(r'^[A-Za-z0-9]+$')));
    expect(await secrets.read(DatabaseKey.secretName), key.value);

    final again = keyFor();
    expect(await again.unlock(), isTrue);
    expect(again.value, key.value);
    expect(DatabaseKey.generate(), isNot(DatabaseKey.generate()));
  });

  test('nothing is readable on disk, and only the key opens it', () async {
    final key = keyFor();
    await key.unlock();
    await write(first(), 'a very private sentence', key: key.value);
    expect(onDiskInClear(first(), 'a very private sentence'), isFalse);
    expect(DatabaseKey.isPlain(File(first())), isFalse);
    expect(await read(first(), key.value), ['a very private sentence']);
    expect(DatabaseKey.opens(File(first()), 'not the key'), isFalse);
    await expectLater(
      openAppDatabase(first(), key: 'not the key'),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('databases from before encryption are encrypted at start', () async {
    await write(first(), 'from 0.2.0');
    await write(second(), 'another companion');
    expect(DatabaseKey.isPlain(File(first())), isTrue);

    final key = keyFor();
    expect(await key.unlock(), isTrue);
    for (final (path, text) in [
      (first(), 'from 0.2.0'),
      (second(), 'another companion'),
    ]) {
      expect(DatabaseKey.isPlain(File(path)), isFalse);
      expect(onDiskInClear(path, text), isFalse);
      expect(await read(path, key.value), [text]);
    }
  });

  test(
    'without the stored key it asks, and takes only the right one',
    () async {
      final key = keyFor();
      await key.unlock();
      await write(first(), 'hello', key: key.value);
      final saved = key.value;

      // Another computer: the database came along, the keyring didn't.
      await secrets.delete(DatabaseKey.secretName);
      final fresh = keyFor();
      expect(await fresh.unlock(), isFalse);
      expect(fresh.unlocked, isFalse);
      expect(await fresh.tryPassword('wrong password'), isFalse);
      expect(await fresh.tryPassword(saved), isTrue);
      expect(await secrets.read(DatabaseKey.secretName), saved);
      expect(await read(first(), fresh.value), ['hello']);
    },
  );

  test('a stored key that no longer fits asks too', () async {
    final key = keyFor();
    await key.unlock();
    await write(first(), 'hello', key: key.value);
    await secrets.write(DatabaseKey.secretName, 'something else');
    expect(await keyFor().unlock(), isFalse);
  });

  test('changing the key re-encrypts every database, open or not', () async {
    final key = keyFor();
    await key.unlock();
    await write(first(), 'one', key: key.value);
    await write(second(), 'two', key: key.value);
    final open = await openAppDatabase(first(), key: key.value);

    await key.change("my own pass'word", open: open, openPath: first());
    expect(key.value, "my own pass'word");
    expect(await secrets.read(DatabaseKey.secretName), "my own pass'word");
    expect(await secrets.read(DatabaseKey.nextName), isNull);
    // The open handle keeps working.
    expect((await open.query('messages')).single['content'], 'one');
    await open.close();

    expect(await read(first(), "my own pass'word"), ['one']);
    expect(await read(second(), "my own pass'word"), ['two']);
    expect(DatabaseKey.opens(File(second()), 'old'), isFalse);
  });

  test('a change cut short is finished at the next start', () async {
    final key = keyFor();
    await key.unlock();
    final old = key.value;
    await write(first(), 'one', key: old);
    await write(second(), 'two', key: old);
    // As if the app stopped after saving the new key and re-encrypting
    // only the first database.
    await secrets.write(DatabaseKey.nextName, 'the new key!');
    final db = await openAppDatabase(first(), key: old);
    await db.execute("PRAGMA rekey = 'the new key!'");
    await db.close();

    final again = keyFor();
    expect(await again.unlock(), isTrue);
    expect(again.value, 'the new key!');
    expect(await read(first(), 'the new key!'), ['one']);
    expect(await read(second(), 'the new key!'), ['two']);
    expect(await secrets.read(DatabaseKey.nextName), isNull);
  });

  test('a lost key sets the old databases aside and starts over', () async {
    final key = keyFor();
    await key.unlock();
    await write(first(), 'gone', key: key.value);
    await secrets.delete(DatabaseKey.secretName);

    final fresh = keyFor();
    expect(await fresh.unlock(), isFalse);
    final aside = await fresh.setAside();
    expect(fresh.unlocked, isTrue);
    expect(File(first()).existsSync(), isFalse);
    expect(File(p.join(aside.path, 'companion.db')).existsSync(), isTrue);
    expect(await secrets.read(DatabaseKey.secretName), fresh.value);
  });

  test('the key counts as kept once copied, typed in or chosen', () async {
    final key = keyFor();
    await key.unlock();
    expect(key.saved, isFalse);
    await key.markSaved();
    expect(keyFor().saved, isTrue);
    await write(first(), 'hello', key: key.value);

    // Typing it in on another computer proves the human has it.
    await secrets.delete(DatabaseKey.secretName);
    await key.markUnsaved();
    final other = keyFor();
    expect(await other.unlock(), isFalse);
    expect(await other.tryPassword(key.value), isTrue);
    expect(other.saved, isTrue);

    // Starting over makes a key nobody has seen yet.
    await secrets.delete(DatabaseKey.secretName);
    final lost = keyFor();
    await lost.unlock();
    await lost.setAside();
    expect(lost.saved, isFalse);
  });
}
