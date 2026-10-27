import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What a log line is about; Settings → Logs filters by it.
enum LogKind {
  browser('Browser'),
  web('Web'),
  thinking('Thinking'),
  decisions('Decisions'),
  chat('Chat'),
  drawing('Drawing'),
  errors('Errors');

  const LogKind(this.label);
  final String label;

  static LogKind parse(String name) =>
      values.where((k) => k.name == name).firstOrNull ?? errors;
}

/// One line in the log.
class LogEntry {
  const LogEntry({
    this.id,
    required this.at,
    required this.kind,
    required this.message,
    this.details = '',
    this.error = false,
  });

  /// Its row in the database; null before it is written.
  final int? id;
  final DateTime at;
  final LogKind kind;
  final String message;

  /// The long part: thoughts, a tool call's arguments and answer, what the
  /// browser printed before it failed.
  final String details;
  final bool error;

  factory LogEntry.fromRow(Map<String, Object?> r) => LogEntry(
    id: r['id'] as int?,
    at: DateTime.tryParse('${r['ts']}')?.toLocal() ?? DateTime.now(),
    kind: LogKind.parse('${r['kind']}'),
    message: '${r['message']}',
    details: '${r['details'] ?? ''}',
    error: r['error'] == 1,
  );

  Map<String, Object?> toRow() => {
    'ts': at.toUtc().toIso8601String(),
    'kind': kind.name,
    'message': message,
    'details': details,
    'error': error ? 1 : 0,
  };

  /// The entry as plain text, for copying and saving.
  String toText() {
    final head =
        '${at.toIso8601String()}  ${kind.label.padRight(9)}'
        '${error ? ' ERROR' : ''}  $message';
    if (details.isEmpty) return head;
    final body = details
        .trimRight()
        .split('\n')
        .map((l) => '    $l')
        .join('\n');
    return '$head\n$body';
  }
}

/// Settings → Logs: what the companion's browser, web tools, thoughts,
/// tool calls, replies and drawing did, so a problem can be traced.
///
/// Lines go into the current companion's database ([db]), so they are
/// encrypted along with the chat when encryption is on. API keys and
/// anything shaped like one are blanked out before a line is kept
/// ([redact]). Lines older than [keepFor], and beyond [maxLines], go.
class AppLog extends ChangeNotifier {
  AppLog({
    required this.db,
    required this.enabled,
    this.secrets,
    this.flushDelay = const Duration(milliseconds: 400),
  });

  /// The database lines are written to; it changes with the companion.
  final Database Function() db;

  /// Whether Settings → Logs keeps lines of this kind.
  final bool Function(LogKind kind) enabled;

  /// The secrets in use now (API keys), blanked out wherever they appear.
  final Iterable<String> Function()? secrets;

  final Duration flushDelay;

  static const keepFor = Duration(days: 7);
  static const maxLines = 5000;
  static const maxDetails = 8000;

  /// The most text kept in all, whatever the number of lines.
  static const maxChars = 8 << 20;

  final _pending = <LogEntry>[];
  Timer? _flush;
  // The first write after starting trims too.
  var _sinceTrim = 200;

  /// Adds a line. Never throws: a log that can't be written never gets in
  /// the companion's way.
  void add(
    LogKind kind,
    String message, {
    String details = '',
    bool error = false,
  }) {
    if (!enabled(kind)) return;
    final known = [...?secrets?.call()];
    var long = redact(details, known);
    if (long.length > maxDetails) {
      long = '${long.substring(0, maxDetails)}\n… (cut)';
    }
    _pending.add(
      LogEntry(
        at: DateTime.now(),
        kind: kind,
        message: redact(message, known),
        details: long,
        error: error,
      ),
    );
    _flush ??= Timer(flushDelay, () => flush().ignore());
  }

  /// Writes the lines waiting to the database.
  Future<void> flush() async {
    _flush?.cancel();
    _flush = null;
    if (_pending.isEmpty) return;
    final lines = [..._pending];
    _pending.clear();
    try {
      final d = db();
      final batch = d.batch();
      for (final l in lines) {
        batch.insert('logs', l.toRow());
      }
      await batch.commit(noResult: true);
      _sinceTrim += lines.length;
      if (_sinceTrim >= 200) {
        _sinceTrim = 0;
        await trim(d);
      }
    } catch (_) {
      // Closed while switching companion, say: those lines are dropped.
    }
    notifyListeners();
  }

  /// Drops lines older than [keepFor] and beyond the newest [maxLines].
  static Future<void> trim(Database d) async {
    final cutoff = DateTime.now().toUtc().subtract(keepFor).toIso8601String();
    await d.delete('logs', where: 'ts < ?', whereArgs: [cutoff]);
    await d.execute(
      'DELETE FROM logs WHERE id <= '
      '(SELECT id FROM logs ORDER BY id DESC LIMIT 1 OFFSET $maxLines)',
    );
    // Long thoughts add up: the oldest tenth goes until it fits.
    for (var i = 0; i < 10; i++) {
      final size = await d.rawQuery(
        'SELECT COALESCE(SUM(LENGTH(message) + LENGTH(details)), 0) AS n, '
        'COUNT(*) AS c FROM logs',
      );
      final n = size.single['n'] as int, c = size.single['c'] as int;
      if (n <= maxChars || c == 0) break;
      await d.execute(
        'DELETE FROM logs WHERE id IN '
        '(SELECT id FROM logs ORDER BY id LIMIT ${(c / 10).ceil()})',
      );
    }
  }

  /// The newest lines first, of [kinds] only when given, and only the
  /// failures with [errorsOnly].
  Future<List<LogEntry>> entries({
    Set<LogKind>? kinds,
    bool errorsOnly = false,
    int limit = 300,
  }) async {
    await flush();
    final where = [
      if (kinds != null && kinds.isNotEmpty)
        'kind IN (${List.filled(kinds.length, '?').join(', ')})',
      if (errorsOnly) 'error = 1',
    ];
    try {
      final rows = await db().query(
        'logs',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: [...?kinds?.map((k) => k.name)],
        orderBy: 'id DESC',
        limit: limit,
      );
      return [for (final r in rows) LogEntry.fromRow(r)];
    } catch (_) {
      return const [];
    }
  }

  /// Every line kept, oldest first, as plain text.
  Future<String> asText({Set<LogKind>? kinds, bool errorsOnly = false}) async {
    final all = await entries(
      kinds: kinds,
      errorsOnly: errorsOnly,
      limit: maxLines,
    );
    return all.reversed.map((e) => e.toText()).join('\n');
  }

  Future<void> clear() async {
    _pending.clear();
    try {
      await db().delete('logs');
    } catch (_) {}
    notifyListeners();
  }

  /// [text] with [secrets] and anything that looks like an API key or a
  /// password blanked out.
  static String redact(String text, [Iterable<String> secrets = const []]) {
    var out = text;
    for (final s in secrets) {
      if (s.trim().length >= 6) out = out.replaceAll(s.trim(), '[hidden]');
    }
    return out
        .replaceAllMapped(_bearer, (m) => '${m[1]}[hidden]')
        .replaceAllMapped(_keyParam, (m) => '${m[1]}[hidden]')
        .replaceAll(_keyShape, '[hidden]');
  }

  static final _bearer = RegExp(
    r'((?:Bearer|Basic|Token)\s+)[A-Za-z0-9._~+/=-]{8,}',
    caseSensitive: false,
  );

  /// `api_key=…`, `"apiKey": "…"`, `password: …` and the like.
  static final _keyParam = RegExp(
    r'''((?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|token|secret|password|passwd|x-api-key|x-subscription-token)["']?\s*[=:]\s*["']?)[^\s"'&,;}]+''',
    caseSensitive: false,
  );

  /// Keys by their usual prefixes: OpenAI, Anthropic, OpenRouter, Tavily,
  /// Hugging Face, GitHub, Google.
  static final _keyShape = RegExp(
    r'\b(?:sk-[A-Za-z0-9_-]{16,}|tvly-[A-Za-z0-9_-]{12,}|hf_[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[A-Za-z0-9_-]{30,})',
  );
}
