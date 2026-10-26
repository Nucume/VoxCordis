import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/desk/desk_files.dart';
import '../../data/desk/desk_tools.dart';
import '../../data/desk/pictures.dart';
import '../../data/memory/memory.dart';
import 'import_temp.dart';
import 'imported_character.dart';
import 'nemini_clock.dart';
import 'untrusted_text.dart';

/// A Nemini.ai export ZIP: `companion.json`, `desk/` (personality.md,
/// lessons.md, privacy.md and the companion's other files),
/// `memory/facts.json` and `turns.jsonl`.
///
/// `providers.json`, `keys.json` and `google.json` hold credentials and are
/// never opened. Nor are prefs, achievements or pet, which have no
/// counterpart here yet. `clock/tasks.json` becomes paused reminders and
/// tasks ([NeminiClock]).
class NeminiExport {
  static const _secrets = {'providers.json', 'keys.json', 'google.json'};

  /// Reads the character from [zip]. Memories, chat and desk files are
  /// counted here and copied by [NeminiExtras.apply] once setup finishes.
  static Future<ImportedCharacter> read(File zip) async {
    final input = InputFileStream(zip.path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } catch (_) {
        throw const ImportException('This is not a ZIP file.');
      }
      final root = _root(archive);
      if (root == null) {
        throw const ImportException(
          'This ZIP is not a Nemini export: it has no companion.json or desk '
          'folder.',
        );
      }
      ArchiveFile? entry(String name) => archive.findFile('$root$name');
      String? text(String name) {
        final f = entry(name);
        if (f == null || !f.isFile) return null;
        return utf8.decode(f.content, allowMalformed: true);
      }

      final companion = _jsonMap(text('companion.json'));
      final persona = _first(companion, const ['companion', 'persona']);
      String pick(List<String> keys) {
        for (final m in [companion, persona]) {
          for (final k in keys) {
            if (m[k] is String && (m[k] as String).trim().isNotEmpty) {
              return m[k] as String;
            }
          }
        }
        return '';
      }

      final personalityText = text('desk/${DeskFiles.personality}');
      final fm = personalityText == null
          ? null
          : Frontmatter.parse(personalityText);
      var name = UntrustedText.line(
        fm?.string('name') ??
            pick(const ['name', 'companion_name', 'display_name']),
        maxChars: 40,
      );
      if (name.isEmpty) name = 'Companion';

      final pronouns =
          pronounsFrom(
            [
              fm?.string('pronouns') ?? '',
              pick(const ['pronouns', 'pronoun', 'gender']),
            ].where((s) => s.isNotEmpty),
          ) ??
          (fm?.string('pronouns') == null
              ? null
              : UntrustedText.line(fm!.string('pronouns')!, maxChars: 30));
      final vibes = companion['vibes'] ?? persona['vibes'];
      final traits = traitsFrom(
        fm?.list('traits') ??
            [
              if (vibes is List)
                for (final v in vibes) '$v',
            ],
      );
      final looks = {
        for (final k in DeskFiles.looksKeys)
          k: UntrustedText.line(fm?.map('looks')?[k] ?? '', maxChars: 200),
      };

      final sections = <ImportSection>[];
      if (personalityText != null) {
        sections.add(
          ImportSection(
            'From my Nemini personality file',
            UntrustedText.clean(
              _withoutFrontmatter(personalityText),
              maxChars: 16000,
              charName: name,
              demoteHeadings: true,
            ),
          ),
        );
      } else {
        final about = pick(const ['persona', 'description', 'bio', 'about']);
        sections.add(
          ImportSection(
            'Who I am',
            UntrustedText.clean(about, maxChars: 8000, charName: name),
          ),
        );
      }

      final userMap = _first(companion, const ['user', 'human']);
      final userName = UntrustedText.line(
        [
              companion['user_name'],
              companion['userName'],
              userMap['name'],
              userMap['nickname'],
            ].whereType<String>().firstOrNull ??
            '',
        maxChars: 40,
      );

      final lessons = text('desk/${DeskFiles.lessons}');
      final privacy = text('desk/${DeskFiles.privacy}');

      final facts = _jsonList(text('memory/facts.json'));
      final tasks = NeminiClock.parse(text('clock/tasks.json'));
      final turns = entry('turns.jsonl');
      final messageCount = turns == null || !turns.isFile
          ? 0
          : '\n'
                .allMatches(utf8.decode(turns.content, allowMalformed: true))
                .length;
      final desk = [
        for (final f in archive.files)
          if (_deskPath(f, root) case final rel?) rel,
      ];

      File? portrait;
      for (final ext in Pictures.extensions) {
        final f = entry('desk/avatar.$ext') ?? entry('avatar.$ext');
        if (f == null || !f.isFile) continue;
        final bytes = f.content;
        final real = Pictures.imageExtensionOf(bytes);
        if (real == null) continue;
        final dir = await ImportTemp.create();
        portrait = File(p.join(dir.path, 'avatar.$real'));
        await portrait.writeAsBytes(bytes);
        break;
      }

      return ImportedCharacter(
        source: 'Nemini',
        name: name,
        pronouns: pronouns,
        traits: traits,
        looks: looks,
        sections: sections,
        portrait: portrait,
        lessons: lessons == null
            ? null
            : UntrustedText.cut(
                UntrustedText.clean(lessons, charName: name),
                DeskFiles.lessonsMaxChars,
              ),
        privacy: privacy == null
            ? null
            : UntrustedText.clean(
                privacy,
                maxChars: DeskFiles.privacyMaxChars,
                charName: name,
              ),
        userName: userName.isEmpty ? null : userName,
        notes: [
          'API keys and account links (providers, keys, Google) were not '
              'read.',
          'Achievements and the pet stay behind for now.',
        ],
        nemini: NeminiExtras(
          zipPath: zip.path,
          root: root,
          factCount: facts.length,
          messageCount: messageCount,
          taskCount: tasks.length,
          deskFiles: desk.where(isPlainDeskFile).toList(),
          otherFiles: desk.where((f) => !isPlainDeskFile(f)).toList(),
        ),
      );
    } finally {
      await input.close();
    }
  }

  /// The folder inside the ZIP that holds the export: '' or 'name/'.
  static String? _root(Archive archive) {
    String? best;
    for (final f in archive.files) {
      final n = f.name.replaceAll('\\', '/');
      for (final marker in const ['companion.json', 'desk/', 'turns.jsonl']) {
        final i = n.indexOf(marker);
        if (i < 0) continue;
        final prefix = n.substring(0, i);
        if (prefix.isNotEmpty && !prefix.endsWith('/')) continue;
        if ('/'.allMatches(prefix).length > 1) continue;
        if (best == null || prefix.length < best.length) best = prefix;
      }
    }
    return best;
  }

  /// Bigger desk files are left in the export.
  static const maxDeskFileBytes = 64 * 1024 * 1024;

  /// The path below `desk/` of a file that may be copied into the
  /// companion folder, or null. Leaves out the three files the import maps
  /// itself, core.md, avatars, links, secrets, files over
  /// [maxDeskFileBytes], and anything that could climb out of the folder.
  static String? _deskPath(ArchiveFile f, String root) {
    if (!f.isFile || f.isSymbolicLink) return null;
    final n = f.name.replaceAll('\\', '/');
    if (!n.startsWith('${root}desk/')) return null;
    final rel = n.substring('${root}desk/'.length);
    final parts = rel.split('/');
    if (rel.isEmpty ||
        parts.any((s) => s.isEmpty || s == '.' || s == '..') ||
        rel.contains(':') ||
        p.isAbsolute(rel)) {
      return null;
    }
    final lower = rel.toLowerCase();
    if (parts.length == 1 &&
        ({...DeskFiles.protected, 'core.md'}.contains(lower) ||
            lower.startsWith('avatar.'))) {
      return null;
    }
    if (_secrets.contains(parts.last.toLowerCase())) return null;
    if (f.size > maxDeskFileBytes) return null;
    return rel;
  }

  /// Whether a desk file is a note or a picture, which come over with the
  /// desk. Anything else (a script, a program, a document) is listed
  /// apart and only copied when the human ticks it.
  static bool isPlainDeskFile(String rel) {
    final lower = rel.toLowerCase();
    if (lower.endsWith('.') || lower.endsWith(' ')) return false;
    return DeskTools.textExtensions.contains(p.extension(lower)) ||
        Pictures.hasImageExtension(lower);
  }

  static String _withoutFrontmatter(String text) {
    final t = text.replaceAll('\r\n', '\n');
    if (!t.startsWith('---')) return t;
    final end = t.indexOf('\n---', 3);
    if (end < 0) return t;
    final after = t.indexOf('\n', end + 4);
    return after < 0 ? '' : t.substring(after + 1);
  }

  static Map _jsonMap(String? text) {
    if (text == null) return const {};
    try {
      final v = jsonDecode(text);
      return v is Map ? v : const {};
    } on FormatException {
      return const {};
    }
  }

  static List _jsonList(String? text) {
    if (text == null) return const [];
    try {
      final v = jsonDecode(text);
      if (v is List) return v;
      if (v is Map && v['facts'] is List) return v['facts'] as List;
      return const [];
    } on FormatException {
      return const [];
    }
  }

  static Map _first(Map m, List<String> keys) {
    for (final k in keys) {
      if (m[k] is Map) return m[k] as Map;
    }
    return const {};
  }
}

/// What a Nemini export brings besides the character, and the human's
/// choice for each.
class NeminiExtras {
  NeminiExtras({
    required this.zipPath,
    required this.root,
    required this.factCount,
    required this.messageCount,
    this.taskCount = 0,
    required this.deskFiles,
    this.otherFiles = const [],
  });

  final String zipPath;
  final String root;
  final int factCount;
  final int messageCount;

  /// Reminders and automations in `clock/tasks.json`.
  final int taskCount;

  /// Notes and pictures, copied when [desk] is on.
  final List<String> deskFiles;

  /// Everything else on the desk: scripts, programs, documents. Each is
  /// copied only when the human ticks it into [chosenOthers].
  final List<String> otherFiles;
  final Set<String> chosenOthers = {};

  bool memories = true;
  bool chat = true;
  bool desk = true;
  bool tasks = true;

  /// Copies what the human kept ticked. Re-running it never duplicates:
  /// memories and messages keep their Nemini ids, and files that already
  /// exist in [folder] are left alone.
  Future<({int memories, int messages, int files, int tasks})> apply({
    required Database db,
    required String folder,
  }) async {
    var memoryCount = 0, messageCount = 0, fileCount = 0, taskCount = 0;
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      String? text(String name) {
        final f = archive.findFile('$root$name');
        if (f == null || !f.isFile) return null;
        return utf8.decode(f.content, allowMalformed: true);
      }

      if (memories) {
        final batch = db.batch();
        for (final f in NeminiExport._jsonList(text('memory/facts.json'))) {
          final m = _memory(f);
          if (m == null) continue;
          batch.insert(
            'memories',
            m.toRow(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          memoryCount++;
        }
        await batch.commit(noResult: true);
      }

      if (chat) {
        final turns = text('turns.jsonl');
        if (turns != null) {
          final rows = await db.rawQuery(
            'SELECT coalesce(max(sort_order), 0) AS n FROM messages',
          );
          final base = rows.single['n'] as int;
          final parsed =
              [
                for (final line in const LineSplitter().convert(turns))
                  if (_message(line) case final m?) m,
              ]..sort((a, b) {
                final byTime = a.$1.$1.compareTo(b.$1.$1);
                return byTime != 0 ? byTime : a.$1.$2.compareTo(b.$1.$2);
              });
          final batch = db.batch();
          for (final (i, (_, row)) in parsed.indexed) {
            batch.insert('messages', {
              ...row,
              'sort_order': base + i + 1,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
          await batch.commit(noResult: true);
          messageCount = parsed.length;
        }
      }

      if (tasks) {
        // Paused, for the human to look at in the Plans tab first. The id
        // comes from Nemini's, so importing again adds nothing twice.
        final batch = db.batch();
        final now = DateTime.now().toUtc().toIso8601String();
        for (final t in NeminiClock.parse(text('clock/tasks.json'))) {
          batch.insert('schedules', {
            'id': const Uuid().v5(Namespace.url.value, 'nemini-task:${t.id}'),
            'kind': t.kind.name,
            'text': t.text,
            'next_at': t.at.toUtc().toIso8601String(),
            'repeat': t.repeat.code,
            'active': 0,
            'created_at': now,
            'origin': 'nemini',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          taskCount++;
        }
        await batch.commit(noResult: true);
      }

      final wanted = {if (desk) ...deskFiles, ...chosenOthers};
      if (wanted.isNotEmpty) {
        final rootDir = p.normalize(p.absolute(folder));
        for (final f in archive.files) {
          final rel = NeminiExport._deskPath(f, root);
          if (rel == null || !wanted.contains(rel)) continue;
          final target = p.normalize(p.joinAll([rootDir, ...rel.split('/')]));
          if (!p.isWithin(rootDir, target)) continue;
          final out = File(target);
          if (await out.exists()) continue;
          await out.parent.create(recursive: true);
          final stream = OutputFileStream(target);
          f.writeContent(stream);
          await stream.close();
          fileCount++;
        }
      }
    } finally {
      await input.close();
    }
    return (
      memories: memoryCount,
      messages: messageCount,
      files: fileCount,
      tasks: taskCount,
    );
  }

  static Memory? _memory(Object? f) {
    if (f is! Map) return null;
    final text = UntrustedText.line(_s(f['text']), maxChars: 2000);
    if (text.isEmpty) return null;
    final now = DateTime.now();
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    String? short(Object? v) {
      final s = UntrustedText.line(_s(v), maxChars: 200);
      return s.isEmpty ? null : s;
    }

    final id = _s(f['uuid']).isNotEmpty ? _s(f['uuid']) : _s(f['id']);
    if (id.isEmpty || id.length > 64) return null;
    return Memory(
      id: id,
      text: text,
      subject: short(f['subject']),
      predicate: short(f['predicate']),
      object: short(f['object']),
      category: short(f['category']) ?? 'general',
      priority: f['priority'] is num
          ? (f['priority'] as num).round().clamp(0, 100)
          : 50,
      validFrom: date(f['valid_from']) ?? date(f['recorded_at']) ?? now,
      validTo: date(f['valid_to']),
      recordedAt: date(f['recorded_at']) ?? date(f['valid_from']) ?? now,
      reinforcedCount: f['reinforced_count'] is num
          ? (f['reinforced_count'] as num).round()
          : 0,
      origin: 'nemini',
      sourceIds: [
        if (f['source_content_uuids'] is List)
          for (final s in f['source_content_uuids'] as List)
            if (s is String) s,
      ],
    );
  }

  /// A chat line as a messages row (without sort_order), with the order
  /// to put it in: by time, then Nemini's own order.
  static ((String, num), Map<String, Object?>)? _message(String line) {
    if (line.trim().isEmpty) return null;
    final Object? m;
    try {
      m = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (m is! Map) return null;
    final role = _s(m['role']);
    if (role != 'user' && role != 'assistant') return null;
    final id = _s(m['uuid']).isNotEmpty ? _s(m['uuid']) : _s(m['id']);
    final ts = DateTime.tryParse(_s(m['ts']));
    final content = UntrustedText.clean(_s(m['content']));
    if (id.isEmpty || ts == null || content.isEmpty) return null;
    final reasoning = UntrustedText.clean(_s(m['reasoning']));
    final utc = ts.toUtc().toIso8601String();
    return (
      (utc, m['sort_order'] is num ? m['sort_order'] as num : 0),
      {
        'id': id,
        'ts': utc,
        'role': role,
        'content': content,
        'via': _s(m['via']).isEmpty ? 'nemini' : 'nemini-${_s(m['via'])}',
        'reasoning': reasoning.isEmpty ? null : reasoning,
      },
    );
  }

  static String _s(Object? v) => v is String ? v : (v is num ? '$v' : '');
}
