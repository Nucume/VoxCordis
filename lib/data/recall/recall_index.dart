import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../memory/memory.dart';
import '../message_repository.dart';

/// One hit of a search by meaning.
typedef Hit = ({String id, double score});

/// The `vectors` table: what each memory and each chat moment means, as a
/// unit vector from the Recall embedding model, and the search over them.
///
/// A moment is an exchange: the human's message and the reply after it,
/// keyed by the human's message id. Vectors are compared with a plain dot
/// product (they are unit length, so that is the cosine), over every row
/// of a kind: a companion's memories and chat are thousands of rows at
/// most, which takes milliseconds.
class RecallIndex {
  RecallIndex(this._db);

  final Database _db;

  static const memoryKind = 'memory';
  static const momentKind = 'moment';

  /// Saves (or replaces) the vectors of [vectors]'s ids.
  Future<void> putAll(
    String kind,
    String model,
    Map<String, Float32List> vectors,
  ) async {
    if (vectors.isEmpty) return;
    final batch = _db.batch();
    for (final MapEntry(key: id, value: v) in vectors.entries) {
      batch.insert('vectors', {
        'kind': kind,
        'id': id,
        'model': model,
        'vector': encode(v),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> remove(String kind, Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.delete(
      'vectors',
      where: 'kind = ? AND id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: [kind, ...list],
    );
  }

  /// Drops vectors whose memory or message is gone.
  Future<void> sweep() async {
    await _db.delete(
      'vectors',
      where:
          "(kind = ? AND id NOT IN (SELECT id FROM memories)) OR "
          "(kind = ? AND id NOT IN (SELECT id FROM messages))",
      whereArgs: [memoryKind, momentKind],
    );
  }

  /// Current memories that have no vector from [model] yet.
  Future<List<Memory>> memoriesWithout(String model, {int? limit}) async {
    final rows = await _db.rawQuery(
      'SELECT m.* FROM memories m '
      'LEFT JOIN vectors v ON v.kind = ? AND v.id = m.id AND v.model = ? '
      'WHERE m.valid_to IS NULL AND v.id IS NULL '
      'ORDER BY m.recorded_at DESC'
      '${limit == null ? '' : ' LIMIT $limit'}',
      [memoryKind, model],
    );
    return rows.map(Memory.fromRow).toList();
  }

  /// The human's messages that have no moment vector from [model] yet,
  /// newest first.
  Future<List<ChatMessage>> momentsWithout(String model, {int? limit}) async {
    final rows = await _db.rawQuery(
      'SELECT u.* FROM messages u '
      'LEFT JOIN vectors v ON v.kind = ? AND v.id = u.id AND v.model = ? '
      "WHERE u.role = 'user' AND v.id IS NULL "
      'ORDER BY u.sort_order DESC'
      '${limit == null ? '' : ' LIMIT $limit'}',
      [momentKind, model],
    );
    return rows.map(ChatMessage.fromRow).toList();
  }

  /// How many vectors of [kind] [model] made.
  Future<int> count(String kind, String model) async {
    final rows = await _db.rawQuery(
      'SELECT count(*) AS n FROM vectors WHERE kind = ? AND model = ?',
      [kind, model],
    );
    return rows.first['n'] as int;
  }

  /// The [limit] ids of [kind] closest in meaning to [query], best first,
  /// with at least [minScore]. Memories count only while current; moments
  /// only while their message exists.
  Future<List<Hit>> search(
    String kind,
    String model,
    Float32List query, {
    int limit = 8,
    double minScore = 0,
  }) async {
    final rows = await _db.rawQuery(
      kind == memoryKind
          ? 'SELECT v.id, v.vector FROM vectors v '
                'JOIN memories m ON m.id = v.id '
                'WHERE v.kind = ? AND v.model = ? AND m.valid_to IS NULL'
          : 'SELECT v.id, v.vector FROM vectors v '
                'JOIN messages m ON m.id = v.id '
                'WHERE v.kind = ? AND v.model = ?',
      [kind, model],
    );
    final hits = <Hit>[];
    for (final r in rows) {
      final v = decode(r['vector'] as Uint8List);
      if (v.length != query.length) continue;
      final score = dot(query, v);
      if (score >= minScore) hits.add((id: r['id'] as String, score: score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// A vector as stored: 32-bit floats, in this machine's byte order (every
  /// desktop VoxCordis runs on is little-endian).
  static Uint8List encode(Float32List v) => Uint8List.fromList(
    v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes),
  );

  static Float32List decode(Uint8List bytes) =>
      // A copy, so the floats start on an aligned address.
      Uint8List.fromList(bytes).buffer.asFloat32List();

  static double dot(Float32List a, Float32List b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  /// [v] scaled to unit length (unchanged when it is all zeros).
  static Float32List normalize(List<num> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = sum == 0 ? 1.0 : 1 / sqrt(sum);
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] * norm;
    }
    return out;
  }
}
