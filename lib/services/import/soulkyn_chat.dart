import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/memory/memory.dart';
import 'imported_character.dart';
import 'untrusted_text.dart';

/// One message of a Soulkyn chat export.
class SoulkynChatLine {
  const SoulkynChatLine({
    required this.fromKyn,
    required this.text,
    required this.ts,
  });

  /// Written by the Kyn; else by the human.
  final bool fromKyn;
  final String text;
  final DateTime ts;
}

/// A chat thread exported from Soulkyn as CSV: `Created At`, `From` and
/// `Message`, one row per message, oldest first. `From` is "System", the
/// Kyn's name or the human's Soulkyn username.
///
/// The first System row is the Kyn's scenario intro; another one is
/// Soulkyn's hidden "(Out of context: Generate the opening … greets
/// `<persona>` …)" instruction, which is dropped, but it names the human's
/// character. A reply has the same time as the message it answers, so the
/// order is the file's.
class SoulkynChat {
  const SoulkynChat({
    required this.kynName,
    required this.userHandle,
    required this.persona,
    required this.intro,
    required this.lines,
  });

  /// The Kyn's name as Soulkyn shows it.
  final String kynName;

  /// The human's Soulkyn username, as in `From`. Kept out of what is
  /// imported; only used to tell their messages apart.
  final String userHandle;

  /// The name the human went by in the chat: the character they played.
  final String persona;

  /// The scenario the Kyn sets at the start, cleaned; may be empty.
  final String intro;

  /// The messages, in order, without the System rows.
  final List<SoulkynChatLine> lines;

  /// Most messages read from one file; Soulkyn threads rarely come near.
  static const maxLines = 20000;

  /// Most characters kept of one message.
  static const maxChars = 20000;

  static const _header = ['created at', 'from', 'message'];

  DateTime get first => lines.first.ts;
  DateTime get last => lines.last.ts;

  /// Reads [file]; throws [ImportException] when it isn't a Soulkyn chat.
  static Future<SoulkynChat> read(File file) async {
    final size = await file.length();
    if (size > 64 << 20) {
      throw const ImportException('This file is too big to be a chat export.');
    }
    final bytes = await file.readAsBytes();
    return parse(utf8.decode(bytes, allowMalformed: true));
  }

  /// Whether [file] looks like a Soulkyn chat export, by its first line.
  static Future<bool> looksLikeOne(File file) async {
    if (p.extension(file.path).toLowerCase() != '.csv') return false;
    try {
      final raf = await file.open();
      try {
        final head = utf8.decode(await raf.read(200), allowMalformed: true);
        return isHeader(head.split('\n').first);
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  static bool isHeader(String line) {
    final cells = rows(line).firstOrNull ?? const [];
    return cells.length >= 3 &&
        [for (final c in cells.take(3)) c.trim().toLowerCase()].join('|') ==
            _header.join('|');
  }

  static SoulkynChat parse(String text) {
    final all = rows(text);
    if (all.isEmpty || !isHeader(all.first.join(','))) {
      throw const ImportException(
        'This isn\'t a Soulkyn chat export: it should start with the '
        'columns Created At, From and Message.',
      );
    }
    final body = [
      for (final r in all.skip(1))
        if (r.length >= 3 && r.any((c) => c.trim().isNotEmpty)) r,
    ];
    final system = [
      for (final r in body)
        if (r[1].trim().toLowerCase() == 'system') r[2],
    ];
    final hidden = system.where(_isHiddenPrompt).toList();
    final intro = system.where((s) => !_isHiddenPrompt(s)).join('\n\n');

    // Who is who: the hidden prompt names the Kyn ("Generate the opening
    // <Kyn> greets …"); else the Kyn writes first.
    final speakers = <String>[];
    for (final r in body) {
      final f = r[1].trim();
      if (f.isEmpty || f.toLowerCase() == 'system') continue;
      if (!speakers.contains(f)) speakers.add(f);
    }
    if (speakers.isEmpty) {
      throw const ImportException('There are no messages in this chat.');
    }
    final named = hidden.map(_kynInPrompt).nonNulls.firstOrNull;
    var kyn = speakers.first;
    if (named != null) {
      kyn = speakers.firstWhere(
        (s) => s.toLowerCase() == named.toLowerCase(),
        orElse: () => kyn,
      );
    }
    final user = speakers.firstWhere((s) => s != kyn, orElse: () => '');

    final lines = <SoulkynChatLine>[];
    DateTime? last;
    for (final r in body) {
      final from = r[1].trim();
      if (from.isEmpty || from.toLowerCase() == 'system') continue;
      // A third name (a Kyn renamed mid-thread) is still the Kyn's side.
      final fromKyn = from != user;
      final ts = DateTime.tryParse(r[0].trim())?.toUtc() ?? last;
      if (ts == null) continue;
      last = ts;
      final t = UntrustedText.clean(
        r[2],
        maxChars: maxChars,
      ).replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
      if (t.isEmpty) continue;
      lines.add(SoulkynChatLine(fromKyn: fromKyn, text: t, ts: ts));
      if (lines.length >= maxLines) break;
    }
    if (lines.isEmpty) {
      throw const ImportException('There are no messages in this chat.');
    }
    final persona = UntrustedText.line(
      hidden.map(_personaInPrompt).nonNulls.firstOrNull ?? user,
      maxChars: 40,
    );
    return SoulkynChat(
      kynName: UntrustedText.line(kyn, maxChars: 60),
      userHandle: user,
      persona: persona.isEmpty ? 'You' : persona,
      intro: UntrustedText.clean(intro, maxChars: 8000).trim(),
      lines: lines,
    );
  }

  static final _hiddenPrompt = RegExp(
    r'^\s*\(?\s*out of context\s*:',
    caseSensitive: false,
  );

  static bool _isHiddenPrompt(String s) => _hiddenPrompt.hasMatch(s);

  static String? _kynInPrompt(String s) => RegExp(
    r'generate the opening\s+(.+?)\s+greets\s',
    caseSensitive: false,
  ).firstMatch(s)?.group(1)?.trim();

  static String? _personaInPrompt(String s) => RegExp(
    r'\sgreets\s+(.+?)\s+(?:according to|in|with|based on)\s',
    caseSensitive: false,
  ).firstMatch(s)?.group(1)?.trim();

  /// The rows of a CSV text (RFC 4180: quoted fields may hold commas,
  /// line breaks and doubled quotes).
  static List<List<String>> rows(String text) {
    final out = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    var i = 0;
    if (text.startsWith('﻿')) i = 1;
    void endCell() {
      row.add(cell.toString());
      cell.clear();
    }

    void endRow() {
      endCell();
      out.add(row);
      row = <String>[];
    }

    while (i < text.length) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i += 2;
            continue;
          }
          quoted = false;
        } else {
          cell.write(c);
        }
        i++;
        continue;
      }
      switch (c) {
        case '"' when cell.isEmpty:
          quoted = true;
        case ',':
          endCell();
        case '\r':
          if (i + 1 < text.length && text[i + 1] == '\n') i++;
          endRow();
        case '\n':
          endRow();
        default:
          cell.write(c);
      }
      i++;
    }
    if (cell.isNotEmpty || row.isNotEmpty) endRow();
    return out;
  }

  // ----- What kind of chat it is.

  /// The Kyn runs a game rather than being one person: a list of
  /// /commands in the intro, scene headers, group chats where it writes
  /// for many people, or "RPG" in its name.
  bool get looksLikeAGame => gameSigns >= 2;

  /// How many of the signs of a game the chat shows.
  int get gameSigns {
    var n = 0;
    if (RegExp(r'\brpg\b', caseSensitive: false).hasMatch(kynName)) n += 2;
    if (RegExp(r'^\s*/[a-z]+', multiLine: true).allMatches(intro).length >= 2) {
      n++;
    }
    final kynText = [
      for (final l in lines)
        if (l.fromKyn) l.text,
    ].join('\n');
    if (_place.allMatches(kynText).length >= 2) n++;
    if (handles.length >= 3) n++;
    return n;
  }

  /// `📍 **Room 2 — Evening**`: where a scene starts, Soulkyn's RPG style.
  static final _place = RegExp(
    r'^\s*📍\s*\**\s*(.+?)\s*\**\s*$',
    multiLine: true,
  );

  /// The place named by the last scene header in [text], if any.
  static String? placeIn(String text) {
    final all = _place.allMatches(text).toList();
    if (all.isEmpty) return null;
    final place = all.last.group(1)!.replaceAll('*', '').trim();
    return place.isEmpty ? null : place;
  }

  /// `> **@nadia_k 💙** - **(11:47 PM):**`: the people writing in the
  /// group chats a game Kyn shows, by handle.
  Set<String> get handles => {
    for (final l in lines)
      if (l.fromKyn)
        for (final m in RegExp(
          r'^>\s*\**@([\w.]+)',
          multiLine: true,
        ).allMatches(l.text))
          m.group(1)!.toLowerCase(),
  };

  // ----- Ids that stay the same when the same chat is imported again.

  /// A message's id: the same each time the same message is imported, so
  /// importing a chat again (or a longer export of it) adds only what's new.
  String idOf(SoulkynChatLine l) => const Uuid().v5(
    Namespace.url.value,
    'soulkyn-chat:${kynName.toLowerCase()}|${l.ts.toIso8601String()}|'
    '${l.fromKyn ? 'kyn' : 'human'}|${sha1.convert(utf8.encode(l.text))}',
  );

  /// The Kyn as a companion to set up, with this chat along. A chat holds
  /// no character sheet, so only the scenario comes over as prose.
  ImportedCharacter asCharacter() => ImportedCharacter(
    source: 'a Soulkyn chat',
    name: kynName.isEmpty ? 'Companion' : kynName,
    sections: [
      if (intro.isNotEmpty) ImportSection('How our story began', intro),
    ],
    userName: persona == 'You' ? null : persona,
    notes: [
      'A chat export has no character sheet, so their personality is up '
          'to you here. For the full character and pictures, import the '
          'Kyn\'s page link instead and add this chat on the next step.',
      if (looksLikeAGame)
        'This chat looks like an RPG, where the Kyn plays many people. It '
            'may fit Voces Mundi better, as a story to go on with.',
    ],
  )..soulkynChat = this;

  /// The Kyn's first message, when the chat starts with it: a story's
  /// opening.
  String? get opening => lines.first.fromKyn ? lines.first.text : null;
}

/// Puts a [SoulkynChat] into a companion's chat history.
class SoulkynChatImport {
  /// Adds the chat's messages to [db] and returns how many were new (a
  /// message already there from an earlier import is left alone).
  ///
  /// When the companion's own chat only began after the Soulkyn chat
  /// ended, the Soulkyn chat goes in front of it, so the chat reads in the
  /// order it happened; otherwise it follows. When [persona] isn't the
  /// name the companion knows the human by ([userName]), a memory says so,
  /// so the old messages make sense to it.
  static Future<int> intoCompanion(
    Database db,
    SoulkynChat chat, {
    String? userName,
    DateTime? now,
  }) async {
    final ids = [for (final l in chat.lines) chat.idOf(l)];
    final have = <String>{};
    for (var i = 0; i < ids.length; i += 500) {
      final part = ids.sublist(i, (i + 500).clamp(0, ids.length));
      final rows = await db.query(
        'messages',
        columns: ['id'],
        where: 'id IN (${List.filled(part.length, '?').join(',')})',
        whereArgs: part,
      );
      have.addAll(rows.map((r) => r['id']! as String));
    }
    final fresh = [
      for (final (i, l) in chat.lines.indexed)
        if (!have.contains(ids[i])) (ids[i], l),
    ];
    if (fresh.isEmpty) return 0;

    await db.transaction((txn) async {
      final span = await txn.rawQuery(
        'SELECT min(ts) AS first, coalesce(max(sort_order), 0) AS top, '
        'count(*) AS n FROM messages',
      );
      final first = DateTime.tryParse('${span.single['first'] ?? ''}');
      final top = span.single['top']! as int;
      final before =
          (span.single['n']! as int) > 0 &&
          first != null &&
          !first.toUtc().isBefore(fresh.last.$2.ts);
      var base = top;
      if (before) {
        // Make room at the front; the story so far moves up with the
        // messages it was about.
        final shift = fresh.length;
        await txn.rawUpdate('UPDATE messages SET sort_order = sort_order + ?', [
          shift,
        ]);
        await txn.rawUpdate('UPDATE story SET through = through + ?', [shift]);
        base = 0;
      }
      final batch = txn.batch();
      for (final (i, (id, l)) in fresh.indexed) {
        batch.insert('messages', {
          'id': id,
          'ts': l.ts.toIso8601String(),
          'role': l.fromKyn ? 'assistant' : 'user',
          'content': l.text,
          'via': 'soulkyn',
          'sort_order': base + i + 1,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);

      final name = userName?.trim() ?? '';
      if (name.isNotEmpty &&
          chat.persona.toLowerCase() != name.toLowerCase() &&
          chat.persona != 'You') {
        final at = now ?? DateTime.now();
        final text =
            'In our older chats from Soulkyn, my human went by '
            '"${chat.persona}".';
        final id = const Uuid().v5(
          Namespace.url.value,
          'soulkyn-chat-persona:${chat.kynName.toLowerCase()}|'
          '${chat.persona.toLowerCase()}',
        );
        await txn.insert(
          'memories',
          Memory(
            id: id,
            text: text,
            subject: 'my human',
            predicate: 'went by',
            object: chat.persona,
            category: 'relationship',
            priority: 60,
            validFrom: at,
            recordedAt: at,
            origin: 'soulkyn',
          ).toRow(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
    return fresh.length;
  }
}
