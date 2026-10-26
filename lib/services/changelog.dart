import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'updater.dart' show appVersion, compareVersions;

/// One version's notes from CHANGELOG.md.
@immutable
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.notes,
    this.actions = const [],
  });

  final String version;

  /// Markdown, without the version heading and without action lines.
  final String notes;

  /// Ids from `{{action:<id>}}` lines, in order ([WhatsNewAction]).
  final List<String> actions;
}

final _heading = RegExp(r'^##\s+v?(\d+\.\d+\.\d+\S*)');
final _action = RegExp(r'^\s*\{\{action:([a-z0-9-]+)\}\}\s*$');

/// Reads CHANGELOG.md: each `## x.y.z` heading starts a version (anything
/// after the number, like a date, is ignored); other `##` headings, such as
/// "Unreleased", are skipped. Newest first, whatever order the file has.
List<ChangelogEntry> parseChangelog(String markdown) {
  final entries = <ChangelogEntry>[];
  String? version;
  var lines = <String>[];
  var actions = <String>[];
  void flush() {
    if (version != null) {
      entries.add(
        ChangelogEntry(
          version: version,
          notes: lines.join('\n').trim(),
          actions: actions,
        ),
      );
    }
    lines = [];
    actions = [];
  }

  for (final line in markdown.split('\n')) {
    if (line.startsWith('## ')) {
      flush();
      version = _heading.firstMatch(line)?.group(1);
    } else if (version != null) {
      final a = _action.firstMatch(line);
      if (a != null) {
        actions.add(a.group(1)!);
      } else {
        lines.add(line);
      }
    }
  }
  flush();
  entries.sort((a, b) => compareVersions(b.version, a.version));
  return entries;
}

/// The versions after [from] up to and including [to], newest first: what
/// someone who updated from [from] hasn't seen yet.
List<ChangelogEntry> changesSince(
  List<ChangelogEntry> all,
  String from,
  String to,
) => [
  for (final e in all)
    if (compareVersions(e.version, from) > 0 &&
        compareVersions(e.version, to) <= 0)
      e,
];

/// Remembers which version last ran, so the first start after an update can
/// show what changed in every version since, including any that were
/// skipped.
class WhatsNew {
  WhatsNew(this._file, {this.current = appVersion});

  static WhatsNew inSupportDir(Directory supportDir) =>
      WhatsNew(File(p.join(supportDir.path, 'last_version')));

  final File _file;
  final String current;

  /// Builds before this one didn't record their version. An install that
  /// was already set up came from one of them; 0.2.0 is the newest.
  static const untrackedBefore = '0.2.0';

  /// The version this install ran before, and the notes to show at this
  /// start, newest first. The notes are empty when there is nothing new (a
  /// fresh install, the same version, a downgrade). Records [current] as
  /// seen, so they show only once.
  Future<({String? from, List<ChangelogEntry> notes})> pending({
    required bool wasSetUp,
    Future<String> Function()? readChangelog,
  }) async {
    String? last;
    try {
      if (await _file.exists()) last = (await _file.readAsString()).trim();
    } catch (_) {
      // Unreadable: treated like a build that didn't record it.
    }
    if (last == null || last.isEmpty) last = wasSetUp ? untrackedBefore : null;
    if (last != current) {
      try {
        await _file.parent.create(recursive: true);
        await _file.writeAsString(current, flush: true);
      } catch (_) {
        // Shown again next start; better than never.
      }
    }
    if (last == null || compareVersions(current, last) <= 0) {
      return (from: last, notes: const <ChangelogEntry>[]);
    }
    try {
      return (
        from: last,
        notes: changesSince(
          parseChangelog(await (readChangelog ?? bundledChangelog)()),
          last,
          current,
        ),
      );
    } catch (_) {
      // Notes are a courtesy; never let them stop the app.
      return (from: last, notes: const <ChangelogEntry>[]);
    }
  }

  /// The newest notes this build has, for Settings → About.
  static Future<ChangelogEntry?> latest({
    Future<String> Function()? readChangelog,
  }) async {
    final all = parseChangelog(await (readChangelog ?? bundledChangelog)());
    for (final e in all) {
      if (compareVersions(e.version, appVersion) <= 0) return e;
    }
    // A test build of the next version shows the newest notes there are.
    return all.firstOrNull;
  }

  static Future<String> bundledChangelog() =>
      rootBundle.loadString('CHANGELOG.md');
}
