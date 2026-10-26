import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/desk/desk_files.dart';
import 'package:companion/data/memory/memory_repository.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/services/export/companion_export.dart';
import 'package:companion/services/import/import_writer.dart';
import 'package:companion/services/import/nemini_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late Database db;
  late AppSettings s;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('export-test');
    db = await openAppDatabase(inMemoryDatabasePath);
    final folder = p.join(tmp.path, 'VoxCordis', 'Ivy');
    s = const AppSettings().copyWith(
      companionName: 'Ivy',
      pronouns: 'she/her',
      traits: ['curious', 'warm'],
      userName: 'Sam',
      companionFolder: folder,
    );
    await DeskFiles.ensure(s);
    final garden = await File(
      p.join(folder, 'notes', 'garden.md'),
    ).create(recursive: true);
    garden.writeAsStringSync('Tomatoes in May.');
    File(p.join(folder, 'core.md')).writeAsStringSync('house rules');
    File(p.join(folder, '.directory')).writeAsStringSync('system');

    final memory = MemoryRepository(db);
    await memory.remember(text: 'Sam likes tea', subject: 'Sam');
    final gone = await memory.remember(text: 'Sam hates mornings');
    await db.update(
      'memories',
      {'forgotten_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [gone.id],
    );
    for (final (i, (role, text)) in [
      ('user', 'Hi Ivy'),
      ('assistant', 'Hello Sam!'),
    ].indexed) {
      await db.insert('messages', {
        'id': 'm$i',
        'ts': DateTime.utc(2026, 10, 26, 12, i).toIso8601String(),
        'role': role,
        'content': text,
        'via': 'app',
        'sort_order': i + 1,
      });
    }
    await db.insert('schedules', {
      'id': 's1',
      'kind': 'reminder',
      'text': 'Water the tomatoes',
      'next_at': DateTime.utc(2026, 11, 1, 8).toIso8601String(),
      'repeat': 'weekly',
      'active': 1,
      'created_at': DateTime.utc(2026, 10, 1).toIso8601String(),
      'origin': 'chat',
    });
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('a plain export has the Nemini layout and no secrets', () async {
    final out = File(p.join(tmp.path, 'Ivy.zip'));
    final r = await CompanionExport.write(
      settings: s.copyWith(llmApiKey: 'sk-secret'),
      db: db,
      out: out,
    );
    expect(r.memories, 1);
    expect(r.messages, 2);
    expect(r.tasks, 1);
    expect(File('${out.path}.part').existsSync(), isFalse);

    final zip = ZipDecoder().decodeBytes(out.readAsBytesSync());
    final names = zip.files.map((f) => f.name).toSet();
    expect(
      names,
      containsAll([
        'companion.json',
        'memory/facts.json',
        'turns.jsonl',
        'clock/tasks.json',
        'desk/personality.md',
        'desk/lessons.md',
        'desk/privacy.md',
        'desk/notes/garden.md',
      ]),
    );
    expect(names, isNot(contains('desk/core.md')));
    expect(names, isNot(contains('desk/.directory')));
    String text(String n) => utf8.decode(zip.findFile(n)!.content);
    for (final n in names) {
      expect(text(n), isNot(contains('sk-secret')), reason: n);
    }
    final facts = jsonDecode(text('memory/facts.json')) as List;
    expect(facts.single['text'], 'Sam likes tea');
    expect(jsonDecode(text('companion.json'))['format'], 'voxcordis-companion');
  });

  test('a locked export needs its password, then imports back', () async {
    final out = File(p.join(tmp.path, 'Ivy.zip'));
    await CompanionExport.write(
      settings: s,
      db: db,
      out: out,
      password: 'tomatoes123',
    );

    await expectLater(
      NeminiExport.read(out),
      throwsA(
        isA<ZipPasswordException>().having((e) => e.wrong, 'wrong', false),
      ),
    );
    await expectLater(
      NeminiExport.read(out, password: 'potatoes123'),
      throwsA(
        isA<ZipPasswordException>().having((e) => e.wrong, 'wrong', true),
      ),
    );

    final c = await NeminiExport.read(out, password: 'tomatoes123');
    expect(c.source, 'VoxCordis');
    expect(c.name, 'Ivy');
    expect(c.pronouns, 'she/her');
    expect(c.traits, ['curious', 'warm']);
    expect(c.userName, 'Sam');
    expect(c.nemini!.factCount, 1);

    // A second in-memory database would be the same one.
    final db2 = await openAppDatabase(p.join(tmp.path, 'second.db'));
    final folder = p.join(tmp.path, 'VoxCordis', 'Ivy 2');
    final s2 = s.copyWith(companionFolder: folder);
    final r = await ImportWriter.write(
      c,
      s2,
      body: c.body,
      looks: c.looks,
      db: db2,
    );
    expect(r.memories, 1);
    expect(r.messages, 2);
    expect(r.tasks, 1);
    expect(
      File(p.join(folder, 'notes', 'garden.md')).readAsStringSync(),
      'Tomatoes in May.',
    );
    final personality = File(
      p.join(folder, DeskFiles.personality),
    ).readAsStringSync();
    expect('# About this file'.allMatches(personality).length, 1);

    final messages = await db2.query('messages', orderBy: 'sort_order');
    expect(messages.map((m) => m['content']), ['Hi Ivy', 'Hello Sam!']);
    expect(messages.first['via'], 'app');
    final plans = await db2.query('schedules');
    expect(plans.single['active'], 0);
    expect(plans.single['origin'], 'import');
    expect(plans.single['repeat'], 'weekly');
    await db2.close();
  });

  test('the suggested name is safe on every system', () {
    expect(
      CompanionExport.suggestedName('Ivy: the "best"?', DateTime(2026, 1, 5)),
      'Ivy the best-2026-01-05.zip',
    );
    expect(
      CompanionExport.suggestedName('///', DateTime(2026, 1, 5)),
      'Companion-2026-01-05.zip',
    );
  });
}
