import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
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
/// of a kind.
///
/// The vectors of a kind are read from the database once and then held in
/// memory ([_Held]), about 3 KB each: read afresh for every search, a long
/// chat's tens of megabytes came out of the encrypted file and across to
/// the window's thread for each reply.
class RecallIndex {
  RecallIndex(this._db);

  final Database _db;

  /// What is held of each kind, once a search asked for it.
  final _held = <String, _Held>{};

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
    final held = _held[kind];
    if (held == null) return;
    // Another model's vectors, or rows that may have replaced another
    // model's: read again at the next search rather than guessed at.
    if (held.model != model || held.others > 0) {
      _held.remove(kind);
      return;
    }
    for (final MapEntry(key: id, value: v) in vectors.entries) {
      if (!held.put(id, v)) {
        _held.remove(kind);
        return;
      }
    }
  }

  Future<void> remove(String kind, Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.delete(
      'vectors',
      where: 'kind = ? AND id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: [kind, ...list],
    );
    final held = _held[kind];
    if (held == null) return;
    if (held.others > 0) {
      _held.remove(kind);
      return;
    }
    list.forEach(held.remove);
  }

  /// Drops vectors whose memory or message is gone.
  Future<void> sweep() async {
    final gone = await _db.delete(
      'vectors',
      where:
          "(kind = ? AND id NOT IN (SELECT id FROM memories)) OR "
          "(kind = ? AND id NOT IN (SELECT id FROM messages))",
      whereArgs: [memoryKind, momentKind],
    );
    if (gone > 0) _held.clear();
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
    for (var tries = 0; ; tries++) {
      final held = await _holding(kind, model);
      final hits = await held.score(
        query,
        minScore,
        // Twice interrupted by vectors coming or going: once through
        // without a pause, so it gets an answer.
        pauses: tries < 2,
      );
      if (hits == null) continue;
      hits.sort((a, b) => b.score.compareTo(a.score));
      // The best ones are checked against the tables, a handful at a
      // time: a fact since replaced, or a message since deleted, may
      // still have its vector.
      final out = <Hit>[];
      final step = limit * 2 > 32 ? limit * 2 : 32;
      for (var at = 0; at < hits.length && out.length < limit; at += step) {
        final part = hits.sublist(
          at,
          at + step < hits.length ? at + step : hits.length,
        );
        final live = await _live(kind, [for (final h in part) h.id]);
        for (final h in part) {
          if (live.contains(h.id) && out.length < limit) out.add(h);
        }
      }
      return out;
    }
  }

  /// The vectors of [kind] that [model] made, read from the database
  /// unless they are held and still what the table has.
  Future<_Held> _holding(String kind, String model) async {
    final held = _held[kind];
    if (held != null && held.model == model) {
      // Vectors also go with their memory or message, deleted elsewhere:
      // the count shows it, read from the table's index alone.
      final rows = await _db.rawQuery(
        'SELECT count(*) AS n FROM vectors WHERE kind = ?',
        [kind],
      );
      if (rows.first['n'] == held.count + held.others) return held;
    }
    final rows = await _db.rawQuery(
      'SELECT id, model, vector FROM vectors WHERE kind = ?',
      [kind],
    );
    final fresh = _Held(model, room: rows.length);
    for (final r in rows) {
      if (r['model'] != model ||
          !fresh.putBytes(r['id'] as String, r['vector'] as Uint8List)) {
        fresh.others++;
      }
    }
    return _held[kind] = fresh;
  }

  /// Which of [ids] still count: current memories, or messages that exist.
  Future<Set<String>> _live(String kind, List<String> ids) async {
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await _db.rawQuery(
      kind == memoryKind
          ? 'SELECT id FROM memories WHERE valid_to IS NULL AND id IN ($marks)'
          : 'SELECT id FROM messages WHERE id IN ($marks)',
      ids,
    );
    return {for (final r in rows) r['id'] as String};
  }

  /// How many vectors of [kind] are held in memory, for tests.
  @visibleForTesting
  int? heldCount(String kind) => _held[kind]?.count;

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

/// One kind's vectors from one model, side by side in a single list so a
/// search runs straight through them.
class _Held {
  _Held(this.model, {int room = 0}) : _roomFor = room;

  final String model;

  /// How many vectors are about to come, so the list is made once at that
  /// size instead of grown to it.
  final int _roomFor;

  /// How long each vector is; 0 until the first one is in.
  int dim = 0;
  int count = 0;

  /// Rows the table has that aren't held: another model's, or ones of
  /// another length.
  int others = 0;

  final ids = <String>[];
  final _rowOf = <String, int>{};
  Float32List _data = Float32List(0);

  /// Goes up with every change, so a search that paused knows its place
  /// in the list is no longer good.
  int _version = 0;

  int _room(String id, int length) {
    if (dim == 0) dim = length;
    final known = _rowOf[id];
    if (known != null) return known;
    if ((count + 1) * dim > _data.length) {
      var rows = count < 8 ? 16 : count * 2;
      if (rows < _roomFor) rows = _roomFor;
      final grown = Float32List(rows * dim);
      grown.setRange(0, count * dim, _data);
      _data = grown;
    }
    ids.add(id);
    return _rowOf[id] = count++;
  }

  /// Takes [v] in for [id], replacing what was there. False, with nothing
  /// taken, when it isn't as long as the others.
  bool put(String id, Float32List v) {
    if (v.isEmpty || (dim != 0 && v.length != dim)) return false;
    _version++;
    final row = _room(id, v.length);
    _data.setRange(row * dim, (row + 1) * dim, v);
    return true;
  }

  /// [put] for a vector as stored ([RecallIndex.encode]).
  bool putBytes(String id, Uint8List bytes) {
    final length = bytes.length ~/ 4;
    if (length == 0 || bytes.length % 4 != 0 || (dim != 0 && length != dim)) {
      return false;
    }
    _version++;
    final row = _room(id, length);
    _data.buffer
        .asUint8List(_data.offsetInBytes + row * dim * 4, dim * 4)
        .setRange(0, dim * 4, bytes);
    return true;
  }

  void remove(String id) {
    final row = _rowOf.remove(id);
    if (row == null) return;
    _version++;
    final last = --count;
    if (row != last) {
      // The last one moves into the gap.
      _data.setRange(row * dim, (row + 1) * dim, _data, last * dim);
      final moved = ids[last];
      ids[row] = moved;
      _rowOf[moved] = row;
    }
    ids.removeLast();
  }

  /// Rows scored in one go before the window gets a turn: a couple of
  /// milliseconds' worth.
  static const _slice = 2048;

  /// Every held vector at least [minScore] like [query], in no order. With
  /// [pauses] the window's thread is let go between slices, and the answer
  /// is null when the vectors changed meanwhile: ask again.
  Future<List<Hit>?> score(
    Float32List query,
    double minScore, {
    bool pauses = true,
  }) async {
    final hits = <Hit>[];
    if (query.length != dim) return hits;
    final version = _version;
    final data = _data;
    final n = dim;
    for (var row = 0; row < count; row++) {
      if (pauses && row > 0 && row % _slice == 0) {
        await Future<void>.delayed(Duration.zero);
        if (version != _version) return null;
      }
      final from = row * n;
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += query[i] * data[from + i];
      }
      if (sum >= minScore) hits.add((id: ids[row], score: sum));
    }
    return hits;
  }
}
