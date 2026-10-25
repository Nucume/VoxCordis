import 'dart:io';

import '../../data/desk/desk_files.dart';
import 'nemini_import.dart';
import 'untrusted_text.dart';

/// A character read from another app, before the human has reviewed it.
/// Every text field has already been through [UntrustedText.clean].
class ImportedCharacter {
  ImportedCharacter({
    required this.source,
    required this.name,
    this.pronouns,
    this.traits = const [],
    Map<String, String>? looks,
    this.sections = const [],
    this.portrait,
    this.avatarUrl,
    this.lessons,
    this.privacy,
    this.userName,
    this.notes = const [],
    this.nemini,
  }) : looks = looks ?? {for (final k in DeskFiles.looksKeys) k: ''};

  /// Whether the companion is asked to rewrite the imported prose in its
  /// own words after setup; the human ticks it on the Story step.
  bool rewrite = false;

  /// Where it came from, for the human: "Soulkyn", "a character card"…
  final String source;
  final String name;
  final String? pronouns;
  final List<String> traits;

  /// The `looks:` keys of personality.md.
  final Map<String, String> looks;

  /// Headed prose for personality.md, in order.
  final List<ImportSection> sections;

  /// A picture that came inside the import (a card PNG, a Nemini avatar).
  final File? portrait;

  /// A picture the import only links to. Never fetched without the human
  /// pressing Download (see `avatar_download.dart`).
  final Uri? avatarUrl;

  /// Whole lessons.md and privacy.md, from a Nemini export.
  final String? lessons;
  final String? privacy;

  /// What the old app called the human.
  final String? userName;

  /// What was left out or changed, shown in the review step.
  final List<String> notes;

  /// Memories, chat and files still inside a Nemini ZIP.
  final NeminiExtras? nemini;

  /// The prose that becomes personality.md's body, below the app's own
  /// "About this file" section.
  String get body => [
    for (final s in sections)
      if (s.text.trim().isNotEmpty) '# ${s.heading}\n\n${s.text.trim()}',
  ].join('\n\n');
}

class ImportSection {
  const ImportSection(this.heading, this.text);

  final String heading;
  final String text;
}

/// Why a file could not be imported, in words for the human.
class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns "she", "female", "Woman" and the like into pronouns.
String? pronounsFrom(Iterable<String> words) {
  for (final w in words) {
    final t = w.trim().toLowerCase();
    if (t.contains('/') && t.length <= 30) return t;
    if (RegExp(r'\b(she|her|female|woman|girl|lady)\b').hasMatch(t)) {
      return 'she/her';
    }
    if (RegExp(r'\b(he|him|male|man|boy|guy)\b').hasMatch(t)) {
      return 'he/him';
    }
    if (RegExp(r'\b(they|them|non-?binary|enby)\b').hasMatch(t)) {
      return 'they/them';
    }
  }
  return null;
}

/// Up to five short trait words from tags or a comma list; long phrases
/// are left for the prose.
List<String> traitsFrom(Iterable<String> words) {
  final out = <String>[];
  for (final w in words) {
    final t = UntrustedText.line(
      w,
    ).toLowerCase().replaceAll(RegExp(r'[\[\],:]'), '').trim();
    if (t.isEmpty || t.length > 24 || t.split(' ').length > 2) continue;
    if (!out.contains(t)) out.add(t);
    if (out.length == DeskFiles.maxTraits) break;
  }
  return out;
}
