import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/settings.dart';
import '../updater.dart' show appVersion;

/// Writes a companion to one ZIP laid out like a Nemini.ai export, so the
/// "Import a character" step (Nemini or VoxCordis) can bring it back:
///
/// - `companion.json`: name, pronouns, traits, when and what exported it.
/// - `desk/`: everything in the companion's folder (personality, lessons,
///   privacy, portrait, pictures, notes), but never links or core.md.
/// - `memory/facts.json`: every memory still kept, history included.
/// - `turns.jsonl`: the chat, one message per line.
/// - `clock/tasks.json`: reminders and automations.
///
/// Settings, API keys, the database key and the model never go in. The
/// database is encrypted on disk but a ZIP is not, unless [password] is
/// given: then every file in it is AES-256 encrypted (names stay readable).
class CompanionExport {
  static const format = 'voxcordis-companion';
  static const formatVersion = 1;

  /// Files bigger than this stay behind; the importer skips them anyway.
  static const maxFileBytes = 64 * 1024 * 1024;

  /// What [write] put in the ZIP.
  static Future<ExportSummary> write({
    required AppSettings settings,
    required Database db,
    required File out,
    String? password,
    bool chat = true,
    bool files = true,
    DateTime? now,
  }) async {
    final folder = settings.companionFolder;
    final stamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    // Written beside the target and renamed at the end, so a failed export
    // never leaves half a ZIP under the chosen name.
    final part = File('${out.path}.part');
    final zip = ZipFileEncoder(
      password: password == null || password.isEmpty ? null : password,
    )..create(part.path);
    var memories = 0, messages = 0, tasks = 0, fileCount = 0;
    final skipped = <String>[];
    try {
      void put(String name, String text) =>
          zip.addArchiveFile(ArchiveFile.string(name, text));

      put(
        'companion.json',
        const JsonEncoder.withIndent('  ').convert({
          'format': format,
          'format_version': formatVersion,
          'app_version': appVersion,
          'exported_at': stamp,
          'name': settings.companionName,
          'pronouns': settings.pronouns,
          'vibes': settings.traits,
          if (settings.userName.trim().isNotEmpty)
            'user_name': settings.userName,
        }),
      );

      // Forgotten memories are on their way out, so they stay behind.
      final facts = await db.query(
        'memories',
        where: 'forgotten_at IS NULL',
        orderBy: 'recorded_at',
      );
      put(
        'memory/facts.json',
        const JsonEncoder.withIndent(
          '  ',
        ).convert([for (final m in facts) _fact(m)]),
      );
      memories = facts.length;

      if (chat) {
        final rows = await db.query('messages', orderBy: 'sort_order');
        final buffer = StringBuffer();
        for (final m in rows) {
          buffer.writeln(
            jsonEncode({
              'uuid': m['id'],
              'ts': m['ts'],
              'role': m['role'],
              'content': m['content'],
              'via': m['via'],
              if (m['reasoning'] != null) 'reasoning': m['reasoning'],
              'sort_order': m['sort_order'],
            }),
          );
        }
        put('turns.jsonl', buffer.toString());
        messages = rows.length;
      }

      final plans = await db.query('schedules', orderBy: 'next_at');
      put(
        'clock/tasks.json',
        const JsonEncoder.withIndent('  ').convert([
          for (final s in plans)
            {
              'uuid': s['id'],
              'type': s['kind'],
              'text': s['text'],
              'next_run': s['next_at'],
              'repeat': s['repeat'],
              'active': s['active'] == 1,
              'created_at': s['created_at'],
            },
        ]),
      );
      tasks = plans.length;

      if (files && folder != null && await Directory(folder).exists()) {
        final root = p.normalize(p.absolute(folder));
        await for (final e in Directory(
          root,
        ).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final rel = p.relative(e.path, from: root);
          final parts = p.split(rel);
          // core.md is the app's house rules, rebuilt on import; hidden
          // files are the system's, not the companion's.
          if (rel == 'core.md' || parts.any((s) => s.startsWith('.'))) {
            continue;
          }
          if (await e.length() > maxFileBytes) {
            skipped.add(rel);
            continue;
          }
          await zip.addFile(e, 'desk/${parts.join('/')}');
          fileCount++;
        }
      }
      await zip.close();
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
    } catch (_) {
      try {
        await zip.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    }
    return ExportSummary(
      memories: memories,
      messages: messages,
      tasks: tasks,
      files: fileCount,
      skipped: skipped,
    );
  }

  /// A memories row in Nemini's facts.json shape.
  static Map<String, Object?> _fact(Map<String, Object?> m) {
    List<Object?> sources() {
      try {
        final v = jsonDecode(m['source_ids'] as String? ?? '[]');
        return v is List ? v : const [];
      } on FormatException {
        return const [];
      }
    }

    return {
      'uuid': m['id'],
      'text': m['text'],
      'subject': m['subject'],
      'predicate': m['predicate'],
      'object': m['object'],
      'category': m['category'],
      'priority': m['priority'],
      'valid_from': m['valid_from'],
      'valid_to': m['valid_to'],
      'recorded_at': m['recorded_at'],
      'reinforced_count': m['reinforced_count'],
      'origin': m['origin'],
      'source_content_uuids': sources(),
    };
  }

  /// A file name like `Haru-2026-10-26.zip`, without characters any
  /// system refuses.
  static String suggestedName(String companion, DateTime now) {
    final safe = companion
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '')
        .trim();
    final day =
        '${now.year}-${'${now.month}'.padLeft(2, '0')}-'
        '${'${now.day}'.padLeft(2, '0')}';
    return '${safe.isEmpty ? 'Companion' : safe}-$day.zip';
  }
}

class ExportSummary {
  const ExportSummary({
    required this.memories,
    required this.messages,
    required this.tasks,
    required this.files,
    this.skipped = const [],
  });

  final int memories;
  final int messages;
  final int tasks;
  final int files;

  /// Folder files too big to go in.
  final List<String> skipped;
}
