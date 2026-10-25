import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core_rules.dart';
import '../settings.dart';
import 'desk_files.dart';
import 'pictures.dart';

/// File tools for the companion's own folder: read, edit, write, and
/// learn_lesson. Paths never leave the folder, core.md is the human's, and
/// the personality, lessons and privacy files are checked on every save.
/// There is no delete or move.
class DeskTools {
  DeskTools({
    required this.settings,
    this.onPersonalitySaved,
    this.onAvatarSet,
    this.onBackgroundSet,
    this.onThemeSet,
  });

  final AppSettings Function() settings;

  /// Called after the companion saves personality.md with its traits, and
  /// its name and pronouns (null when the file has none), so the app's copy
  /// (on the companion card and in Settings) follows the file.
  final Future<void> Function(
    ({List<String> traits, String? name, String? pronouns}) who,
  )?
  onPersonalitySaved;

  /// Called after the companion picks a new portrait, with its file.
  final Future<void> Function(File avatar)? onAvatarSet;

  /// Called when the companion restyles the app: glow colours (ARGB), where
  /// they sit, and the accent. Each is null when left as it was.
  final Future<void> Function(
    ({List<int>? colors, double? layout, int? accent}) look,
  )?
  onBackgroundSet;

  /// Called when the companion switches between light and dark (or back to
  /// following the computer). The human can switch back in Settings.
  final Future<void> Function(ThemeChoice theme)? onThemeSet;

  static const names = {
    'read_file',
    'edit_file',
    'write_file',
    'learn_lesson',
    'set_avatar',
    'set_background',
    'set_theme',
  };

  static const _maxRead = 60000;

  /// Larger files are not read at all, not even the first [_maxRead].
  static const _maxReadBytes = 4 * 1024 * 1024;

  /// What the companion may save: text, nothing a click could run.
  static const textExtensions = {
    '.md',
    '.txt',
    '.json',
    '.csv',
    '.yaml',
    '.yml',
    '.log',
  };

  static const definitions = <Map<String, Object?>>[
    {
      'type': 'function',
      'function': {
        'name': 'read_file',
        'description':
            'Read a text file in your folder, or list a folder. Paths are '
            "relative to your folder, e.g. 'personality.md' or '.'.",
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'edit_file',
        'description':
            'Change a text file in your folder: old_text (copied exactly, '
            'appearing once) is replaced by new_text. Read the file first.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'old_text': {'type': 'string'},
            'new_text': {'type': 'string'},
          },
          'required': ['path', 'old_text', 'new_text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_file',
        'description':
            'Create a text file in your folder, or replace one whole. '
            'For small changes use edit_file.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'learn_lesson',
        'description':
            'Add a lesson to lessons.md when your human corrects how you '
            'behave with them. Do it before you answer.',
        'parameters': {
          'type': 'object',
          'properties': {
            'rule': {
              'type': 'string',
              'description':
                  'The rule, a few words, e.g. "Ask before booking".',
            },
            'why': {'type': 'string', 'description': 'Why, in a few words.'},
          },
          'required': ['rule', 'why'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'set_avatar',
        'description':
            'Make a picture in your folder your portrait, shown beside the '
            'chat. Pictures your human shares are saved in images/. Your '
            'portrait is your choice.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': "e.g. 'images/2026-10-23_231200-me.png'",
            },
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'set_background',
        'description':
            'Restyle the app you live in: the soft colour glows behind the '
            'chat, where they sit, and the accent colour of buttons and '
            'highlights. Your choice, e.g. to suit your mood or a season. '
            'Leave out what should stay.',
        'parameters': {
          'type': 'object',
          'properties': {
            'colors': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  "One to three glow colours, e.g. ['#B18CFF', "
                  "'#4F7CFF', '#FF7AB6']",
            },
            'layout': {
              'type': 'number',
              'description': 'Where the glows sit, from 0 to 1',
            },
            'accent': {'type': 'string', 'description': "e.g. '#B18CFF'"},
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'set_theme',
        'description':
            'Switch the app you live in between light and dark, or back to '
            'following the computer (system). Your choice, e.g. for a sunny '
            'morning, a late night, or to make a point. Your human can '
            'switch it back in Settings.',
        'parameters': {
          'type': 'object',
          'properties': {
            'theme': {
              'type': 'string',
              'enum': ['light', 'dark', 'system'],
            },
          },
          'required': ['theme'],
        },
      },
    },
  ];

  /// `#RRGGBB` (or `RRGGBB`) as an opaque ARGB colour.
  static int parseColor(Object? hex) {
    final m = RegExp(
      r'^#?([0-9a-fA-F]{6})$',
    ).firstMatch(hex is String ? hex.trim() : '');
    if (m == null) throw '"$hex" is not a colour like #B18CFF';
    return 0xFF000000 | int.parse(m[1]!, radix: 16);
  }

  /// Runs one tool call and returns the JSON string sent back to the model.
  Future<String> call(String name, Map<String, Object?> args) async {
    try {
      final s = settings();
      final folder = s.companionFolder;
      if (folder == null) throw 'there is no folder yet';
      switch (name) {
        case 'read_file':
          return await _read(folder, args['path'] as String? ?? '.');
        case 'edit_file':
          final path = args['path'] as String;
          final file = await _resolve(folder, path);
          if (!await file.exists()) throw '$path does not exist';
          final text = await file.readAsString();
          final old = args['old_text'] as String;
          final count = old.isEmpty ? 0 : old.allMatches(text).length;
          if (count != 1) {
            throw count == 0
                ? 'old_text was not found in $path. Read the file and copy it exactly.'
                : 'old_text appears $count times in $path. Include more of the '
                      'surrounding text.';
          }
          return await _save(
            s,
            file,
            text.replaceFirst(old, args['new_text'] as String),
          );
        case 'write_file':
          final file = await _resolve(folder, args['path'] as String);
          return await _save(s, file, args['content'] as String);
        case 'learn_lesson':
          await DeskFiles.ensure(s);
          final file = DeskFiles.fileIn(folder, DeskFiles.lessons);
          final text = await file.readAsString();
          final line = DeskFiles.lessonLine(
            args['rule'] as String,
            args['why'] as String,
            DateTime.now(),
          );
          final sep = text.isEmpty || text.endsWith('\n') ? '' : '\n';
          return await _save(s, file, '$text$sep$line\n');
        case 'set_avatar':
          final path = args['path'] as String;
          final file = await _resolve(folder, path);
          if (!await file.exists()) throw '$path does not exist';
          if (!Pictures.hasImageExtension(path) ||
              !await Pictures.isImage(file)) {
            throw '$path is not a PNG, JPEG or WebP picture';
          }
          final avatar = await Pictures.setAvatar(folder, file);
          await onAvatarSet?.call(avatar);
          return jsonEncode({'ok': true, 'avatar': p.basename(avatar.path)});
        case 'set_background':
          final rawColors = args['colors'];
          final colors = rawColors == null
              ? null
              : [for (final c in rawColors as List) parseColor(c)];
          if (colors != null && (colors.isEmpty || colors.length > 3)) {
            throw 'give one to three colours';
          }
          final layout = (args['layout'] as num?)?.toDouble();
          if (layout != null && (layout < 0 || layout > 1)) {
            throw 'layout goes from 0 to 1';
          }
          final accent = args['accent'] == null
              ? null
              : parseColor(args['accent']);
          if (colors == null && layout == null && accent == null) {
            throw 'nothing to change';
          }
          await onBackgroundSet?.call((
            colors: colors,
            layout: layout,
            accent: accent,
          ));
          return jsonEncode({'ok': true});
        case 'set_theme':
          final theme = ThemeChoice.values.asNameMap()[args['theme']];
          if (theme == null) throw 'theme is light, dark or system';
          await onThemeSet?.call(theme);
          return jsonEncode({'ok': true, 'theme': theme.name});
      }
      throw 'unknown tool $name';
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  Future<String> _read(String folder, String path) async {
    final full = await _resolvePath(folder, path);
    if (await Directory(full).exists()) {
      final entries = [
        await for (final e in Directory(full).list())
          e is Directory ? '${p.basename(e.path)}/' : p.basename(e.path),
      ]..sort();
      return jsonEncode({'ok': true, 'path': path, 'entries': entries});
    }
    final file = File(full);
    if (!await file.exists()) throw '$path does not exist';
    if (await file.length() > _maxReadBytes) {
      throw '$path is too big to read';
    }
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      throw '$path is not a text file';
    }
    return jsonEncode({
      'ok': true,
      'path': path,
      'content': text.length > _maxRead ? text.substring(0, _maxRead) : text,
      if (text.length > _maxRead) 'truncated': true,
    });
  }

  Future<String> _save(AppSettings s, File file, String text) async {
    final root = p.normalize(p.absolute(s.companionFolder!));
    final name = p.relative(file.path, from: root);
    final key = canonicalName(name);
    if (key == CoreRules.fileName) {
      throw 'core.md holds your human\'s rules; only they edit it.';
    }
    if (!textExtensions.contains(p.extension(key))) {
      throw 'Only text files can be saved: '
          '${(textExtensions.toList()..sort()).join(', ')}.';
    }
    final previous = await file.exists() ? await file.readAsString() : '';
    final problem = switch (key) {
      DeskFiles.personality => DeskFiles.checkPersonality(
        text,
        maxChars: DeskFiles.personalityMaxChars(s.contextSize),
      ),
      DeskFiles.lessons => DeskFiles.checkLessons(text, previous: previous),
      DeskFiles.privacy => DeskFiles.checkPrivacy(text),
      _ => null,
    };
    if (problem != null) throw 'Not saved. $problem';
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    if (key == DeskFiles.personality) {
      final fm = Frontmatter.parse(text);
      final traits = fm?.list('traits');
      if (traits != null) {
        await onPersonalitySaved?.call((
          traits: traits,
          name: fm?.string('name'),
          pronouns: fm?.string('pronouns'),
        ));
      }
    }
    return jsonEncode({'ok': true, 'path': name, 'chars': text.length});
  }

  /// [name] as Windows and macOS see it: case does not matter, and Windows
  /// drops dots and spaces at the end of a name. `Core.md.` is core.md there,
  /// so the checks on the companion's protected files compare this form.
  static String canonicalName(String name) => p
      .split(name)
      .map((part) => part.toLowerCase().replaceFirst(RegExp(r'[. ]+$'), ''))
      .join('/');

  Future<File> _resolve(String folder, String path) async =>
      File(await _resolvePath(folder, path));

  /// The absolute path for [path] inside [folder]; throws if it would point
  /// outside, including through a symlink.
  static Future<String> _resolvePath(String folder, String path) async {
    // A colon names a drive, or on Windows a hidden stream of a file
    // (core.md:x), which would get past the checks on the file itself.
    if (path.contains(':')) throw 'Only files inside your folder are allowed.';
    final root = p.normalize(p.absolute(folder));
    final full = p.normalize(p.join(root, path));
    if (full != root && !p.isWithin(root, full)) {
      throw 'Only files inside your folder are allowed.';
    }
    // Follow links on the deepest part that exists.
    var probe = full;
    while (!await FileSystemEntity.isDirectory(probe) &&
        !await File(probe).exists() &&
        probe != root) {
      probe = p.dirname(probe);
    }
    final realRoot = await Directory(root).resolveSymbolicLinks();
    final real = await FileSystemEntity.isDirectory(probe)
        ? await Directory(probe).resolveSymbolicLinks()
        : await File(probe).resolveSymbolicLinks();
    if (real != realRoot && !p.isWithin(realRoot, real)) {
      throw 'Only files inside your folder are allowed.';
    }
    return full;
  }
}
