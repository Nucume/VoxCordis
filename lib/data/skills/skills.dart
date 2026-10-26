import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'builtin_skills.dart';

/// One skill: know-how the companion reads before doing something, kept in
/// `skills/<id>/SKILL.md` in its folder. The file has the same shape as a
/// Claude skill (a `name` and `description` header, then instructions), so
/// those can be imported as they are.
class Skill {
  const Skill({
    required this.id,
    required this.description,
    required this.body,
    this.title,
    this.always = false,
    this.on = false,
    this.review = false,
    this.builtIn = false,
    this.files = const [],
    this.problem,
  });

  /// The folder name, also the command: `/<id>`.
  final String id;

  /// Shown in lists; the id in words when the file has no `title`.
  final String? title;
  final String description;

  /// The instructions below the header.
  final String body;

  /// Placed in every prompt while on, instead of being read when it fits:
  /// a way of being, like ADHD support, rather than a job.
  final bool always;

  /// Whether the companion uses it on its own. Its human can call any
  /// skill with its command, on or off.
  final bool on;

  /// Written by the companion itself and not checked by its human yet:
  /// it stays off until they turn it on.
  final bool review;

  /// One of the starter skills VoxCordis brings.
  final bool builtIn;

  /// Other files in the skill's folder, relative to it.
  final List<String> files;

  /// Why SKILL.md can't be used, or null.
  final String? problem;

  String get command => '/$id';

  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final words = id.replaceAll('-', ' ');
    return words[0].toUpperCase() + words.substring(1);
  }

  /// SKILL.md for this skill.
  String toMarkdown() => Skills.markdown(
    id: id,
    title: title,
    description: description,
    always: always,
    body: body,
  );
}

/// The companion's skills: loading them from its folder, the starter
/// skills, turning them on and off, writing and importing them, and what
/// the prompt says about them.
class Skills {
  static const folderName = 'skills';
  static const fileName = 'SKILL.md';

  /// Which skills are on, and which ones have been seen. It is the human's:
  /// the companion's file tools refuse to change it.
  static const stateFile = 'skills.json';
  static String get statePath => '$folderName/$stateFile';

  static const maxIdChars = 40;
  static const maxDescriptionChars = 400;
  static const maxBodyChars = 20000;

  /// Most bytes an imported skill may bring along, all files together.
  static const maxImportBytes = 2 << 20;

  static final _id = RegExp(r'^[a-z0-9][a-z0-9-]*$');

  /// Null when [id] can name a skill, else what is wrong.
  static String? checkId(String id) {
    if (id.isEmpty) return 'Give the skill a name.';
    if (id.length > maxIdChars) {
      return 'Keep the name under $maxIdChars characters.';
    }
    if (!_id.hasMatch(id)) {
      return 'Use small letters, digits and dashes, like "price-watch".';
    }
    return null;
  }

  /// [text] as a skill name: "Price Watch!" becomes "price-watch".
  static String idFrom(String text) {
    final id = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return id.length > maxIdChars
        ? id.substring(0, maxIdChars).replaceAll(RegExp(r'-+$'), '')
        : id;
  }

  static Directory dirIn(String folder) =>
      Directory(p.join(folder, folderName));

  // ---------------------------------------------------------------- state

  static Future<({Set<String> on, Set<String> seen, Set<String> review})>
  _state(String folder) async {
    final f = File(p.join(folder, folderName, stateFile));
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      Set<String> set(String key) => {
        for (final v in (json[key] as List?) ?? const []) '$v',
      };
      return (on: set('on'), seen: set('seen'), review: set('review'));
    } on Object {
      return (on: <String>{}, seen: <String>{}, review: <String>{});
    }
  }

  static Future<void> _saveState(
    String folder,
    ({Set<String> on, Set<String> seen, Set<String> review}) s,
  ) async {
    final f = File(p.join(folder, folderName, stateFile));
    await f.parent.create(recursive: true);
    List<String> sorted(Set<String> v) => v.toList()..sort();
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'on': sorted(s.on),
        'seen': sorted(s.seen),
        'review': sorted(s.review),
      }),
    );
  }

  // ----------------------------------------------------------------- load

  /// Every skill in [folder], sorted by title. Starter skills not written
  /// yet are written first; skills that turned up since the last look
  /// (the companion wrote them) are kept off for the human to check.
  static Future<List<Skill>> load(String folder) async {
    final state = await _state(folder);
    var changed = false;
    final dir = dirIn(folder);
    for (final b in BuiltInSkills.all) {
      if (state.seen.contains(b.id)) continue;
      final file = File(p.join(dir.path, b.id, fileName));
      if (!await file.exists()) {
        await file.parent.create(recursive: true);
        await file.writeAsString(b.toMarkdown());
      }
      state.seen.add(b.id);
      if (b.on) state.on.add(b.id);
      changed = true;
    }
    final skills = <Skill>[];
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is! Directory) continue;
        final id = p.basename(e.path);
        if (checkId(id) != null) continue;
        if (!state.seen.contains(id)) {
          state.seen.add(id);
          state.review.add(id);
          changed = true;
        }
        skills.add(await _read(e, id, state.on, state.review));
      }
    }
    // Forget deleted ones' switches, but keep them seen so a deleted
    // starter skill doesn't come back.
    final ids = {for (final s in skills) s.id};
    if (state.on.any((id) => !ids.contains(id)) ||
        state.review.any((id) => !ids.contains(id))) {
      state.on.removeWhere((id) => !ids.contains(id));
      state.review.removeWhere((id) => !ids.contains(id));
      changed = true;
    }
    if (changed) await _saveState(folder, state);
    skills.sort((a, b) => a.displayTitle.compareTo(b.displayTitle));
    return skills;
  }

  static Future<Skill> _read(
    Directory dir,
    String id,
    Set<String> on,
    Set<String> review,
  ) async {
    final file = File(p.join(dir.path, fileName));
    final files = <String>[];
    try {
      await for (final e in dir.list(recursive: true)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: dir.path);
        if (rel != fileName) files.add(p.posix.joinAll(p.split(rel)));
      }
    } on FileSystemException {
      // Unreadable extras don't spoil the skill.
    }
    files.sort();
    final builtIn = BuiltInSkills.ids.contains(id);
    String? problem;
    var parsed = (header: const <String, String>{}, body: '');
    if (!await file.exists()) {
      problem = 'It has no $fileName.';
    } else if (await file.length() > maxBodyChars * 2) {
      problem = '$fileName is too long.';
    } else {
      try {
        parsed = parse(await file.readAsString());
      } on FileSystemException {
        problem = '$fileName is not a text file.';
      }
    }
    final description = parsed.header['description']?.trim() ?? '';
    if (problem == null && description.isEmpty) {
      problem = '$fileName needs a "description:" line at the top.';
    }
    if (problem == null && parsed.body.trim().isEmpty) {
      problem = '$fileName has no instructions.';
    }
    return Skill(
      id: id,
      title: parsed.header['title'],
      description: description.length > maxDescriptionChars
          ? '${description.substring(0, maxDescriptionChars)}…'
          : description,
      body: parsed.body.trim(),
      always: parsed.header['always']?.toLowerCase() == 'true',
      on: problem == null && on.contains(id),
      review: review.contains(id),
      builtIn: builtIn,
      files: files,
      problem: problem,
    );
  }

  /// The header and instructions of a SKILL.md. Lenient: plain, quoted and
  /// folded (`>` or `|`) values; keys it doesn't know are kept but unused.
  static ({Map<String, String> header, String body}) parse(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') {
      return (header: const {}, body: text);
    }
    final end = lines.indexWhere((l) => l.trim() == '---', 1);
    if (end < 0) return (header: const {}, body: text);
    final header = <String, String>{};
    String? blockKey;
    final block = <String>[];
    var folded = true;
    void closeBlock() {
      if (blockKey == null) return;
      header[blockKey!] = (folded ? block.join(' ') : block.join('\n')).trim();
      blockKey = null;
      block.clear();
    }

    for (final line in lines.sublist(1, end)) {
      final indented = line.startsWith(' ') || line.startsWith('\t');
      if (blockKey != null && (indented || line.trim().isEmpty)) {
        block.add(line.trim());
        continue;
      }
      closeBlock();
      if (indented || line.trim().isEmpty || line.trimLeft().startsWith('#')) {
        continue;
      }
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim();
      var value = line.substring(colon + 1).trim();
      if (RegExp(r'^[>|][+-]?$').hasMatch(value)) {
        blockKey = key;
        folded = value.startsWith('>');
        continue;
      }
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value
            .substring(1, value.length - 1)
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', r'\');
      } else if (value.length >= 2 &&
          value.startsWith("'") &&
          value.endsWith("'")) {
        value = value.substring(1, value.length - 1).replaceAll("''", "'");
      }
      header[key] = value;
    }
    closeBlock();
    return (header: header, body: lines.sublist(end + 1).join('\n'));
  }

  /// A SKILL.md with this header and [body].
  static String markdown({
    required String id,
    String? title,
    required String description,
    bool always = false,
    required String body,
  }) {
    String quoted(String v) =>
        '"${v.replaceAll('\n', ' ').replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    return [
      '---',
      'name: $id',
      if (title != null && title.trim().isNotEmpty)
        'title: ${quoted(title.trim())}',
      'description: ${quoted(description.trim())}',
      if (always) 'always: true',
      '---',
      '',
      body.trim(),
      '',
    ].join('\n');
  }

  // --------------------------------------------------------------- change

  /// Turns [id] on or off; either way the human has now looked at it.
  static Future<void> setOn(String folder, String id, bool on) async {
    final state = await _state(folder);
    on ? state.on.add(id) : state.on.remove(id);
    state.review.remove(id);
    await _saveState(folder, state);
  }

  /// Writes a skill the human made or changed. [previousId] is the one it
  /// was saved under, when it is renamed. Null when saved, else why not.
  static Future<String?> save(
    String folder, {
    String? previousId,
    required String id,
    String? title,
    required String description,
    required bool always,
    required String body,
  }) async {
    final problem =
        checkId(id) ??
        (description.trim().isEmpty
            ? 'Say in a line what the skill is for and when to use it.'
            : description.trim().length > maxDescriptionChars
            ? 'Keep the description under $maxDescriptionChars characters.'
            : body.trim().isEmpty
            ? 'Write the instructions.'
            : body.length > maxBodyChars
            ? 'Keep the instructions under $maxBodyChars characters.'
            : null);
    if (problem != null) return problem;
    final dir = dirIn(folder);
    final target = Directory(p.join(dir.path, id));
    final state = await _state(folder);
    if (previousId != null && previousId != id) {
      if (await target.exists()) return 'There is already a skill called $id.';
      final old = Directory(p.join(dir.path, previousId));
      if (await old.exists()) await old.rename(target.path);
      if (state.on.remove(previousId)) state.on.add(id);
    } else if (previousId == null && await target.exists()) {
      return 'There is already a skill called $id.';
    }
    await target.create(recursive: true);
    await File(p.join(target.path, fileName)).writeAsString(
      markdown(
        id: id,
        title: title,
        description: description,
        always: always,
        body: body,
      ),
    );
    state.seen.add(id);
    state.review
      ..remove(id)
      ..remove(previousId);
    // A new skill starts on: its human made it to be used.
    if (previousId == null) state.on.add(id);
    await _saveState(folder, state);
    return null;
  }

  static Future<void> delete(String folder, String id) async {
    if (checkId(id) != null) return;
    final dir = Directory(p.join(dirIn(folder).path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
    final state = await _state(folder);
    state.on.remove(id);
    state.review.remove(id);
    await _saveState(folder, state);
  }

  /// Writes the starter skills again that were deleted or changed, as
  /// VoxCordis brings them.
  static Future<void> restoreBuiltIns(String folder) async {
    final state = await _state(folder);
    for (final b in BuiltInSkills.all) {
      final file = File(p.join(dirIn(folder).path, b.id, fileName));
      await file.parent.create(recursive: true);
      await file.writeAsString(b.toMarkdown());
      state.seen.add(b.id);
      state.review.remove(b.id);
      if (b.on) state.on.add(b.id);
    }
    await _saveState(folder, state);
  }

  /// Brings in a skill from [path]: a SKILL.md (with the files beside it),
  /// any other .md file, or a .zip or .skill archive as Claude skills come.
  /// Returns the new skill's id; throws a message for the human.
  static Future<String> import(String folder, String path) async {
    final ext = p.extension(path).toLowerCase();
    final Map<String, List<int>> files;
    if (ext == '.zip' || ext == '.skill') {
      files = await _fromArchive(File(path));
    } else if (p.basename(path).toUpperCase() == fileName.toUpperCase()) {
      files = await _fromFolder(File(path).parent);
    } else if (ext == '.md' || ext == '.txt') {
      files = {fileName: await File(path).readAsBytes()};
    } else {
      throw 'Pick a SKILL.md, a Markdown file, or a .zip or .skill file.';
    }
    final main = files[fileName];
    if (main == null) throw 'There is no $fileName in it.';
    final String text;
    try {
      text = utf8.decode(main);
    } on FormatException {
      throw '$fileName is not a text file.';
    }
    final parsed = parse(text);
    final stem = p.basenameWithoutExtension(path);
    var id = idFrom(
      parsed.header['name'] ??
          (stem.toUpperCase() == 'SKILL'
              ? p.basename(File(path).parent.path)
              : stem),
    );
    if (checkId(id) != null) id = 'imported-skill';
    final description = parsed.header['description']?.trim() ?? '';
    final markdown = description.isEmpty
        ? Skills.markdown(
            id: id,
            title: parsed.header['title'],
            description:
                'Imported from ${p.basename(path)}. Use it when it fits.',
            body: parsed.body,
          )
        : text;
    final dir = dirIn(folder);
    var unique = id;
    for (var n = 2; await Directory(p.join(dir.path, unique)).exists(); n++) {
      unique = '$id-$n';
    }
    final target = Directory(p.join(dir.path, unique));
    for (final e in files.entries) {
      final out = File(p.join(target.path, e.key));
      await out.parent.create(recursive: true);
      if (e.key == fileName) {
        await out.writeAsString(markdown);
      } else {
        await out.writeAsBytes(e.value);
      }
    }
    final state = await _state(folder);
    state.seen.add(unique);
    state.on.add(unique);
    state.review.remove(unique);
    await _saveState(folder, state);
    return unique;
  }

  /// Text files a skill folder may carry; scripts are left behind, as
  /// nothing in VoxCordis runs them.
  static const _textExtensions = {
    '.md',
    '.txt',
    '.json',
    '.csv',
    '.yaml',
    '.yml',
  };

  static bool _keep(String rel) =>
      rel == fileName || _textExtensions.contains(p.extension(rel));

  static Future<Map<String, List<int>>> _fromFolder(Directory dir) async {
    final out = <String, List<int>>{};
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.posix.joinAll(p.split(p.relative(e.path, from: dir.path)));
      if (!_keep(rel) || rel.split('/').any((s) => s.startsWith('.'))) {
        continue;
      }
      total += await e.length();
      if (total > maxImportBytes) throw 'That skill is too big to import.';
      out[rel] = await e.readAsBytes();
    }
    return out;
  }

  static Future<Map<String, List<int>>> _fromArchive(File file) async {
    if (await file.length() > maxImportBytes * 4) {
      throw 'That file is too big to import.';
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    } on Object {
      throw 'That file is not a skill archive.';
    }
    final names = [
      for (final f in archive.files)
        if (f.isFile) f.name.replaceAll(r'\', '/'),
    ];
    // The skill is the folder holding the shallowest SKILL.md.
    final mains = names.where((n) => p.posix.basename(n) == fileName).toList()
      ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    if (mains.isEmpty) throw 'There is no $fileName in it.';
    final root = p.posix.dirname(mains.first);
    final out = <String, List<int>>{};
    var total = 0;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll(r'\', '/');
      final rel = root == '.' ? name : p.posix.relative(name, from: root);
      final clean = p.posix.normalize(rel);
      if (clean.startsWith('..') ||
          p.posix.isAbsolute(clean) ||
          clean.contains(':') ||
          clean.split('/').any((s) => s.startsWith('.')) ||
          !_keep(clean)) {
        continue;
      }
      final bytes = f.content as List<int>;
      total += bytes.length;
      if (total > maxImportBytes) throw 'That skill is too big to import.';
      out[clean] = bytes;
    }
    return out;
  }

  // --------------------------------------------------------------- prompt

  /// The skill called with a command at the start of [text], like
  /// "/proofreading this email…", or null.
  static Skill? called(String text, List<Skill> skills) {
    final m = RegExp(r'^\s*/([a-z0-9][a-z0-9-]*)(?=\s|$)').firstMatch(text);
    if (m == null) return null;
    for (final s in skills) {
      if (s.id == m[1] && s.problem == null) return s;
    }
    return null;
  }

  /// How much of a skill's instructions fits the memory span: about a
  /// third of it, at roughly 4 characters a token.
  static int bodyCharsFor(int contextSize) =>
      (contextSize * 4 ~/ 3).clamp(3000, maxBodyChars);

  static String _cut(String body, int max) =>
      body.length <= max ? body : '${body.substring(0, max)}\n[…cut short]';

  /// What the prompt says about skills: the ones on, by name and what
  /// they're for, those that are always on in full, and the one [called]
  /// with a command for this reply.
  static String forPrompt(
    List<Skill> skills, {
    Skill? called,
    required int contextSize,
  }) {
    final max = bodyCharsFor(contextSize);
    final on = [
      for (final s in skills)
        if (s.on && s.problem == null) s,
    ];
    final picked = [
      for (final s in on)
        if (!s.always) s,
    ];
    final always = [
      for (final s in on)
        if (s.always && s.id != called?.id) s,
    ];
    final b = StringBuffer('## Your skills\n');
    if (picked.isEmpty) {
      b.write('You have no skills to pick from right now. ');
    } else {
      b.write(
        'Skills are know-how for particular jobs. When one fits what your '
        'human wants, call use_skill with its name first and follow what it '
        'says, in your own voice. Don\'t mention skills unless asked.\n',
      );
      for (final s in picked) {
        b.write('- ${s.id}: ${s.description}\n');
      }
    }
    b.write(
      'Each skill is a file in your folder, skills/<name>/SKILL.md. When '
      'your human asks you to learn how to do something for good, you can '
      'write one yourself with write_file: a header with "name:" and '
      '"description:" between --- lines, then the steps. A new skill you '
      'write waits for your human to turn it on in the Skills tab.',
    );
    for (final s in always) {
      b.write('\n\n### ${s.displayTitle} (always on)\n${_cut(s.body, max)}');
    }
    if (called != null) {
      b.write(
        '\n\n## Skill called up now: ${called.displayTitle}\n'
        'Your human typed ${called.command} to have you use this skill for '
        'this message. Follow it:\n\n${_cut(called.body, max)}',
      );
    }
    return b.toString();
  }

  /// What use_skill sends back for [skill].
  static Map<String, Object?> forTool(
    Skill skill, {
    required int contextSize,
  }) => {
    'ok': true,
    'skill': skill.id,
    'instructions': _cut(skill.body, bodyCharsFor(contextSize)),
    if (skill.files.isNotEmpty)
      'files': [for (final f in skill.files) '$folderName/${skill.id}/$f'],
  };
}
