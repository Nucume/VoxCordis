import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'memory.dart';

/// Reads and writes the `memories` table.
///
/// The app (not the model) calls [recall] before every reply, so recall never
/// depends on a small local model remembering to ask. The model changes
/// memory through [remember], [update] and [forget] (see `memory_tools.dart`).
class MemoryRepository {
  MemoryRepository(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final Database _db;
  final DateTime Function() _now;
  static const _uuid = Uuid();

  Future<Memory> remember({
    required String text,
    String? subject,
    String? predicate,
    String? object,
    String category = 'general',
    int priority = 50,
    String origin = 'chat',
    List<String> sourceIds = const [],
  }) async {
    final now = _now();
    final memory = Memory(
      id: _uuid.v4(),
      text: text,
      subject: subject,
      predicate: predicate,
      object: object,
      category: category,
      priority: priority.clamp(0, 100),
      validFrom: now,
      recordedAt: now,
      origin: origin,
      sourceIds: sourceIds,
    );
    await _db.insert('memories', memory.toRow());
    return memory;
  }

  /// Replaces a current fact with a newer one. The old row gets `valid_to`
  /// and `superseded_by` instead of being deleted, so a bad change can be
  /// undone. Fields not given are carried over from the old fact.
  Future<Memory> update(
    String id, {
    required String text,
    String? subject,
    String? predicate,
    String? object,
    String? category,
    int? priority,
    List<String> sourceIds = const [],
  }) {
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'memories',
        where: 'id = ? AND valid_to IS NULL',
        whereArgs: [id],
      );
      if (rows.isEmpty) {
        throw StateError('No current memory with id $id');
      }
      final old = Memory.fromRow(rows.single);
      final now = _now();
      final next = Memory(
        id: _uuid.v4(),
        text: text,
        subject: subject ?? old.subject,
        predicate: predicate ?? old.predicate,
        object: object ?? old.object,
        category: category ?? old.category,
        priority: (priority ?? old.priority).clamp(0, 100),
        validFrom: now,
        recordedAt: now,
        reinforcedCount: old.reinforcedCount,
        origin: old.origin,
        folderPath: old.folderPath,
        sourceIds: sourceIds,
      );
      await txn.insert('memories', next.toRow());
      await txn.update(
        'memories',
        {'valid_to': now.toUtc().toIso8601String(), 'superseded_by': next.id},
        where: 'id = ?',
        whereArgs: [id],
      );
      return next;
    });
  }

  /// Changes how important a current fact is, without making a new version.
  Future<void> setPriority(String id, int priority) => _db.update(
    'memories',
    {'priority': priority.clamp(0, 100)},
    where: 'id = ? AND valid_to IS NULL',
    whereArgs: [id],
  );

  /// How long a fact the companion forgot can still be restored.
  static const forgottenKeep = Duration(days: 30);

  /// Drops a fact and its superseded history for good. What the human does
  /// from the Memory tab.
  Future<bool> forget(String id) => _db.transaction((txn) async {
    final ids = {id, ...await _olderVersions(txn, id)};
    return await _delete(txn, ids) > 0;
  });

  /// The companion's forget: the fact leaves every prompt but stays in
  /// "Recently forgotten" for [forgottenKeep], so a confused model (or
  /// text that talked it into forgetting) can't wipe what the human can't
  /// get back. Its older versions go at once. Only current facts.
  Future<bool> retire(String id, {DateTime? now}) =>
      _db.transaction((txn) async {
        final row = await txn.query(
          'memories',
          columns: ['id'],
          where: 'id = ? AND valid_to IS NULL',
          whereArgs: [id],
        );
        if (row.isEmpty) return false;
        await _delete(txn, await _olderVersions(txn, id));
        final at = (now ?? DateTime.now()).toUtc().toIso8601String();
        await txn.update(
          'memories',
          {'valid_to': at, 'forgotten_at': at},
          where: 'id = ?',
          whereArgs: [id],
        );
        return true;
      });

  /// Brings a forgotten fact back into the companion's mind.
  Future<void> restore(String id) => _db.update(
    'memories',
    {'valid_to': null, 'forgotten_at': null},
    where: 'id = ? AND forgotten_at IS NOT NULL',
    whereArgs: [id],
  );

  /// Facts the companion forgot, most recent first.
  Future<List<Memory>> forgotten() async {
    final rows = await _db.query(
      'memories',
      where: 'forgotten_at IS NOT NULL',
      orderBy: 'forgotten_at DESC',
    );
    return rows.map(Memory.fromRow).toList();
  }

  /// Deletes facts forgotten longer than [forgottenKeep] ago.
  Future<int> purgeForgotten({DateTime? now}) => _db.delete(
    'memories',
    where: 'forgotten_at IS NOT NULL AND forgotten_at < ?',
    whereArgs: [
      (now ?? DateTime.now()).subtract(forgottenKeep).toUtc().toIso8601String(),
    ],
  );

  /// Every row [id] superseded, directly or further back.
  static Future<Set<String>> _olderVersions(Transaction txn, String id) async {
    final ids = <String>{};
    var frontier = [id];
    while (frontier.isNotEmpty) {
      final older = await txn.query(
        'memories',
        columns: ['id'],
        where:
            'superseded_by IN (${List.filled(frontier.length, '?').join(',')})',
        whereArgs: frontier,
      );
      frontier = [for (final r in older) r['id'] as String];
      ids.addAll(frontier);
    }
    return ids;
  }

  static Future<int> _delete(Transaction txn, Set<String> ids) async {
    if (ids.isEmpty) return 0;
    final inIds = 'id IN (${List.filled(ids.length, '?').join(',')})';
    // Clear the chain's links first so the foreign keys allow the delete.
    await txn.update(
      'memories',
      {'superseded_by': null},
      where: inIds,
      whereArgs: ids.toList(),
    );
    return txn.delete('memories', where: inIds, whereArgs: ids.toList());
  }

  /// Memories to put in the prompt: the top [pinned] by priority, plus up to
  /// [related] current facts whose text or subject/object mention a word from
  /// [query]. Bumps `reinforced_count` on the related ones.
  ///
  /// Keyword matching is a stand-in until sqlite-vec search by meaning lands.
  Future<List<Memory>> recall(
    String query, {
    int pinned = 8,
    int related = 8,
  }) async {
    final top = await _db.query(
      'memories',
      where: 'valid_to IS NULL',
      orderBy: 'priority DESC, reinforced_count DESC, recorded_at DESC',
      limit: pinned,
    );
    final result = {for (final r in top) r['id'] as String: Memory.fromRow(r)};

    final words = query
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.length >= 4)
        .toSet()
        .take(12)
        .toList();
    if (words.isNotEmpty) {
      final clause = List.filled(
        words.length,
        "(lower(text) LIKE ? OR lower(coalesce(subject,'')) LIKE ? OR lower(coalesce(object,'')) LIKE ?)",
      ).join(' OR ');
      final args = [
        for (final w in words) ...['%$w%', '%$w%', '%$w%'],
      ];
      final hits = await _db.query(
        'memories',
        where: 'valid_to IS NULL AND ($clause)',
        whereArgs: args,
        orderBy: 'priority DESC, recorded_at DESC',
        limit: related + pinned,
      );
      final hitIds = <String>[];
      for (final r in hits) {
        final id = r['id'] as String;
        if (result.containsKey(id)) continue;
        if (hitIds.length >= related) break;
        result[id] = Memory.fromRow(r);
        hitIds.add(id);
      }
      if (hitIds.isNotEmpty) {
        await _db.rawUpdate(
          'UPDATE memories SET reinforced_count = reinforced_count + 1 '
          'WHERE id IN (${List.filled(hitIds.length, '?').join(',')})',
          hitIds,
        );
      }
    }
    return result.values.toList();
  }

  Future<List<Memory>> current() async {
    final rows = await _db.query(
      'memories',
      where: 'valid_to IS NULL',
      orderBy: 'priority DESC, recorded_at DESC',
    );
    return rows.map(Memory.fromRow).toList();
  }

  /// The fact and every older version it replaced, newest first.
  Future<List<Memory>> history(String id) async {
    final chain = <Memory>[];
    String? next = id;
    while (next != null) {
      final rows = await _db.query(
        'memories',
        where: 'id = ?',
        whereArgs: [next],
      );
      if (rows.isEmpty) break;
      chain.add(Memory.fromRow(rows.single));
      final older = await _db.query(
        'memories',
        columns: ['id'],
        where: 'superseded_by = ?',
        whereArgs: [next],
      );
      next = older.isEmpty ? null : older.single['id'] as String;
    }
    return chain;
  }
}
