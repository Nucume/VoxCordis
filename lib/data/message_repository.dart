import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.ts,
    required this.role,
    required this.content,
    this.via = 'app',
    this.sortOrder = 0,
    this.reasoning,
  });

  final String id;
  final DateTime ts;

  /// user, assistant or tool.
  final String role;
  final String content;
  final String via;
  final int sortOrder;

  /// What the model thought before replying, if it showed its reasoning.
  final String? reasoning;

  ChatMessage withContent(String c, {String? reasoning}) => ChatMessage(
    id: id,
    ts: ts,
    role: role,
    content: c,
    via: via,
    sortOrder: sortOrder,
    reasoning: reasoning ?? this.reasoning,
  );

  factory ChatMessage.fromRow(Map<String, Object?> r) => ChatMessage(
    id: r['id'] as String,
    ts: DateTime.parse(r['ts'] as String).toLocal(),
    role: r['role'] as String,
    content: r['content'] as String,
    via: r['via'] as String,
    sortOrder: r['sort_order'] as int,
    reasoning: r['reasoning'] as String?,
  );
}

class MessageRepository {
  MessageRepository(this._db);

  final Database _db;
  static const _uuid = Uuid();

  Future<ChatMessage> add(String role, String content) async {
    final rows = await _db.rawQuery(
      'SELECT coalesce(max(sort_order), 0) + 1 AS n FROM messages',
    );
    final next = rows.single['n'] as int;
    final m = ChatMessage(
      id: _uuid.v4(),
      ts: DateTime.now(),
      role: role,
      content: content,
      sortOrder: next,
    );
    await _db.insert('messages', {
      'id': m.id,
      'ts': m.ts.toUtc().toIso8601String(),
      'role': role,
      'content': content,
      'via': m.via,
      'sort_order': next,
    });
    return m;
  }

  Future<void> setContent(String id, String content, {String? reasoning}) =>
      _db.update(
        'messages',
        {
          'content': content,
          if (reasoning != null && reasoning.isNotEmpty) 'reasoning': reasoning,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(String id) =>
      _db.delete('messages', where: 'id = ?', whereArgs: [id]);

  /// How many messages came after [m], on any day.
  Future<int> countAfter(ChatMessage m) async {
    final rows = await _db.rawQuery(
      'SELECT count(*) AS n FROM messages WHERE sort_order > ?',
      [m.sortOrder],
    );
    return rows.first['n'] as int;
  }

  /// Deletes [m] and every message after it, on any day.
  Future<void> deleteFrom(ChatMessage m) => _db.delete(
    'messages',
    where: 'sort_order >= ?',
    whereArgs: [m.sortOrder],
  );

  /// Latest [limit] messages, oldest first.
  Future<List<ChatMessage>> recent({int limit = 200}) async {
    final rows = await _db.query(
      'messages',
      orderBy: 'sort_order DESC',
      limit: limit,
    );
    return rows.reversed.map(ChatMessage.fromRow).toList();
  }

  /// All messages of one local day, oldest first.
  Future<List<ChatMessage>> forDay(DateTime day) async {
    final d =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final rows = await _db.query(
      'messages',
      where: "date(ts, 'localtime') = ?",
      whereArgs: [d],
      orderBy: 'sort_order',
    );
    return rows.map(ChatMessage.fromRow).toList();
  }

  /// Distinct local days that have messages, newest first, for the sidebar.
  Future<List<DateTime>> days() async {
    final rows = await _db.rawQuery(
      "SELECT DISTINCT date(ts, 'localtime') AS d FROM messages ORDER BY d DESC",
    );
    return [for (final r in rows) DateTime.parse(r['d'] as String)];
  }
}
