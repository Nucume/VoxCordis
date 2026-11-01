import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database.dart';
import 'database_key.dart';

/// Brings back chats [DatabaseKey.setAside] moved into a `locked-<time>`
/// folder, once their key is known again: each database there is added to
/// the one now in its place, so nothing written since is lost.
class LockedChats {
  LockedChats(this.key);

  final DatabaseKey key;

  /// Adds every database in [folder] (encrypted with [oldKey]) to the
  /// databases in use, then deletes the folder. [open] is the database the
  /// app has open, at [openPath]. Returns how many messages came back.
  Future<int> bringBack(
    Directory folder,
    String oldKey, {
    required Database open,
    required String openPath,
  }) async {
    final dbs = DatabaseKey.databasesIn(folder);
    if (!dbs.every((f) => DatabaseKey.opens(f, oldKey))) {
      throw StateError("That key doesn't open these chats.");
    }
    var messages = 0;
    for (final from in dbs) {
      final target = p.join(
        key.supportDir.path,
        p.relative(from.path, from: folder.path),
      );
      // Rolls back a write left half done, and brings the tables up to
      // this version, so both sides have the same columns.
      final old = await openAppDatabase(from.path, key: oldKey);
      messages +=
          _firstInt(await old.rawQuery('SELECT count(*) FROM messages')) ?? 0;
      await old.close();
      if (p.equals(target, openPath)) {
        await merge(open, from.path, oldKey);
      } else if (await File(target).exists()) {
        final db = await openAppDatabase(target, key: key.value);
        try {
          await merge(db, from.path, oldKey);
        } finally {
          await db.close();
        }
      } else {
        // Nothing took its place: it goes back as it was, with today's key.
        final db = await openAppDatabase(from.path, key: oldKey);
        await db.execute('PRAGMA rekey = ${DatabaseKey.quote(key.value)}');
        await db.close();
        await Directory(p.dirname(target)).create(recursive: true);
        await from.rename(target);
        continue;
      }
      for (final side in ['', '-journal', '-wal', '-shm']) {
        final f = File('${from.path}$side');
        if (await f.exists()) await f.delete();
      }
    }
    await folder.delete(recursive: true);
    return messages;
  }

  /// Adds what the database at [fromPath] holds to [into]. Its messages go
  /// before the ones [into] has (they are older); rows [into] already has
  /// stay as they are. Logs are left out.
  static Future<void> merge(
    Database into,
    String fromPath,
    String fromKey,
  ) async {
    await into.execute(
      'ATTACH DATABASE ${DatabaseKey.quote(fromPath)} AS earlier '
      'KEY ${DatabaseKey.quote(fromKey)}',
    );
    // Memories point at the ones they replaced; the order rows arrive in
    // doesn't follow that.
    await into.execute('PRAGMA foreign_keys = OFF');
    try {
      await into.transaction((txn) async {
        Future<List<String>> columns(String schema, String table) async => [
          for (final r in await txn.rawQuery(
            'PRAGMA $schema.table_info("$table")',
          ))
            r['name'] as String,
        ];
        final shift =
            _firstInt(
              await txn.rawQuery(
                'SELECT coalesce(max(sort_order), 0) FROM earlier.messages',
              ),
            ) ??
            0;
        await txn.rawUpdate(
          'UPDATE main.messages SET sort_order = sort_order + ?',
          [shift],
        );
        // The story so far follows the messages: the earlier one tells of
        // the older chat; else today's moves up with its messages.
        final earlierStory = await txn.rawQuery(
          'SELECT count(*) AS n FROM earlier.story',
        );
        if ((earlierStory.first['n'] as int) > 0) {
          await txn.rawDelete('DELETE FROM main.story');
          await txn.rawInsert(
            'INSERT INTO main.story SELECT * FROM earlier.story',
          );
        } else {
          await txn.rawUpdate('UPDATE main.story SET through = through + ?', [
            shift,
          ]);
        }
        final tables = await txn.rawQuery(
          "SELECT name FROM earlier.sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT IN ('logs', 'story')",
        );
        for (final t in tables) {
          final table = t['name'] as String;
          final here = await columns('main', table);
          if (here.isEmpty) continue;
          final both = [
            for (final c in await columns('earlier', table))
              if (here.contains(c)) '"$c"',
          ].join(', ');
          await txn.execute(
            'INSERT OR IGNORE INTO main."$table" ($both) '
            'SELECT $both FROM earlier."$table"',
          );
        }
      });
    } finally {
      await into.execute('PRAGMA foreign_keys = ON');
      await into.execute('DETACH DATABASE earlier');
    }
  }

  static int? _firstInt(List<Map<String, Object?>> rows) =>
      rows.isEmpty ? null : rows.first.values.first as int?;
}
