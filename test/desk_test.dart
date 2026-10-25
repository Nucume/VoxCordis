import 'dart:convert';
import 'dart:io';

import 'package:companion/data/desk/desk_files.dart';
import 'package:companion/data/desk/desk_tools.dart';
import 'package:companion/data/desk/pictures.dart';
import 'package:companion/data/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late AppSettings settings;
  List<String>? savedTraits;
  String? savedPronouns;
  String? savedName;
  File? savedAvatar;
  ({List<int>? colors, double? layout, int? accent})? savedLook;
  ThemeChoice? savedTheme;
  late DeskTools tools;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('desk');
    settings = AppSettings(
      companionName: 'Mira',
      pronouns: 'she/her',
      traits: const ['warm', 'nerdy'],
      companionFolder: p.join(dir.path, 'Mira'),
    );
    savedTraits = null;
    savedPronouns = null;
    savedName = null;
    savedAvatar = null;
    savedLook = null;
    savedTheme = null;
    tools = DeskTools(
      settings: () => settings,
      onPersonalitySaved: (who) async {
        savedTraits = who.traits;
        savedPronouns = who.pronouns;
        savedName = who.name;
      },
      onAvatarSet: (f) async => savedAvatar = f,
      onBackgroundSet: (look) async => savedLook = look,
      onThemeSet: (theme) async => savedTheme = theme,
    );
    await DeskFiles.ensure(settings);
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Map<String, dynamic>> run(
    String name,
    Map<String, Object?> args,
  ) async => jsonDecode(await tools.call(name, args)) as Map<String, dynamic>;

  String read(String name) =>
      File(p.join(settings.companionFolder!, name)).readAsStringSync();

  group('personality.md', () {
    test('the starting file has the right shape', () {
      final text = read(DeskFiles.personality);
      expect(DeskFiles.checkPersonality(text, maxChars: 9000), isNull);
      final fm = Frontmatter.parse(text)!;
      expect(fm.list('traits'), ['warm', 'nerdy']);
      expect(fm.map('looks')!.keys, DeskFiles.looksKeys);
      expect(text, contains('# Nerdy'));
    });

    test('a save that breaks the shape is refused with the reason', () async {
      final text = read(DeskFiles.personality);
      var r = await run('write_file', {
        'path': 'personality.md',
        'content': text.replaceFirst('  wears:\n', ''),
      });
      expect(r['ok'], false);
      expect(r['error'], contains('wears'));
      r = await run('edit_file', {
        'path': 'personality.md',
        'old_text': 'traits: [warm, nerdy]',
        'new_text': 'traits: [${List.generate(21, (i) => 't$i').join(', ')}]',
      });
      expect(r['error'], contains('1 to 20'));
      expect(read(DeskFiles.personality), text);
    });

    test('the limit follows the memory span', () {
      expect(DeskFiles.personalityMaxChars(4096), 6000);
      expect(DeskFiles.personalityMaxChars(8192), 9830);
      expect(DeskFiles.personalityMaxChars(32768), 17000);
      final big = '${read(DeskFiles.personality)}${'x' * 20000}';
      expect(
        DeskFiles.checkPersonality(big, maxChars: 17000),
        contains('17000'),
      );
    });

    test('a good edit saves and hands the traits to the app', () async {
      final r = await run('edit_file', {
        'path': 'personality.md',
        'old_text': 'traits: [warm, nerdy]',
        'new_text': 'traits: [warm, nerdy, feral]',
      });
      expect(r['ok'], true);
      expect(savedTraits, ['warm', 'nerdy', 'feral']);
      expect(savedPronouns, 'she/her');
    });

    test(
      'the companion can change its pronouns, and the app follows',
      () async {
        final r = await run('edit_file', {
          'path': 'personality.md',
          'old_text': 'pronouns: she/her',
          'new_text': 'pronouns: they/them',
        });
        expect(r['ok'], true);
        expect(savedPronouns, 'they/them');
        expect(savedName, 'Mira');
      },
    );

    test('an older file gets name and pronouns added', () async {
      final file = DeskFiles.fileIn(
        settings.companionFolder!,
        DeskFiles.personality,
      );
      file.writeAsStringSync(
        read(DeskFiles.personality)
            .replaceFirst('name: Mira\n', '')
            .replaceFirst('pronouns: she/her\n', ''),
      );
      await DeskFiles.ensure(settings);
      final text = read(DeskFiles.personality);
      expect(text, contains('name: Mira\npronouns: she/her\ntraits:'));
      expect(DeskFiles.checkPersonality(text, maxChars: 17000), isNull);
    });

    test('an older file without pronouns still saves', () async {
      final text = read(
        DeskFiles.personality,
      ).replaceFirst('pronouns: she/her\n', '');
      expect(DeskFiles.checkPersonality(text, maxChars: 17000), isNull);
      final r = await run('write_file', {
        'path': 'personality.md',
        'content': text,
      });
      expect(r['ok'], true);
      expect(savedPronouns, isNull);
    });
  });

  group('lessons.md', () {
    test('learn_lesson appends one dated line', () async {
      final r = await run('learn_lesson', {
        'rule': 'Ask before planning my evening',
        'why': 'they like to decide',
      });
      expect(r['ok'], true);
      expect(
        DeskFiles.lessonLines(read(DeskFiles.lessons)).single,
        matches(
          r'^- \*\*Ask before planning my evening\*\* — they like to decide — \d{4}-\d\d-\d\d$',
        ),
      );
    });

    test('too long, too many, or deleting is refused', () async {
      var r = await run('learn_lesson', {'rule': 'x' * 150, 'why': 'because'});
      expect(r['error'], contains('160'));
      for (var i = 0; i < 30; i++) {
        r = await run('learn_lesson', {'rule': 'Rule $i', 'why': 'why'});
        expect(r['ok'], true, reason: '$r');
      }
      r = await run('learn_lesson', {'rule': 'One more', 'why': 'why'});
      expect(r['error'], contains('At most 30'));
      r = await run('edit_file', {
        'path': 'lessons.md',
        'old_text': '- **Rule 3** — why',
        'new_text': 'gone',
      });
      expect(r['ok'], false);
    });
  });

  group('portrait', () {
    // Enough of a PNG for the signature check.
    final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];

    test('set_avatar copies a shared picture to avatar.png', () async {
      final folder = settings.companionFolder!;
      final shared = await Pictures.share(
        folder,
        (await File(p.join(dir.path, 'me.png')).writeAsBytes(png)).path,
        DateTime(2026, 10, 23, 23, 12),
      );
      expect(shared, 'images/2026-10-23_231200-me.png');
      final r = await run('set_avatar', {'path': shared});
      expect(r['ok'], true, reason: '$r');
      expect(Pictures.avatarIn(folder)!.path, p.join(folder, 'avatar.png'));
      expect(savedAvatar!.path, p.join(folder, 'avatar.png'));

      // A JPEG later replaces it; only one portrait is kept.
      await File(
        p.join(folder, 'images', 'b.jpeg'),
      ).writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);
      await run('set_avatar', {'path': 'images/b.jpeg'});
      expect(Pictures.avatarIn(folder)!.path, p.join(folder, 'avatar.jpg'));
      expect(File(p.join(folder, 'avatar.png')).existsSync(), isFalse);
    });

    test('set_avatar refuses what is not a picture, or outside', () async {
      final folder = settings.companionFolder!;
      await File(p.join(folder, 'fake.png')).writeAsString('hello');
      var r = await run('set_avatar', {'path': 'fake.png'});
      expect(r['error'], contains('not a PNG'));
      r = await run('set_avatar', {'path': 'personality.md'});
      expect(r['error'], contains('not a PNG'));
      await File(p.join(dir.path, 'out.png')).writeAsBytes(png);
      r = await run('set_avatar', {'path': '../out.png'});
      expect(r['error'], contains('inside your folder'));
      expect(Pictures.avatarIn(folder), isNull);
    });

    test('a picture chosen at setup becomes the first avatar', () async {
      final picked = await File(
        p.join(dir.path, 'pick.webp'),
      ).writeAsBytes([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]);
      await DeskFiles.ensure(settings.copyWith(portraitPath: picked.path));
      final folder = settings.companionFolder!;
      expect(Pictures.avatarIn(folder)!.path, p.join(folder, 'avatar.webp'));
    });

    test('picture lines are found and hidden from the text', () {
      const text = 'Look!\n\n[image: images/a.png]\n[image: images/b.jpg]';
      expect(Pictures.inText(text), ['images/a.png', 'images/b.jpg']);
      expect(Pictures.withoutMarkers(text), 'Look!');
    });
  });

  group('folder safety', () {
    test('paths outside the folder are refused', () async {
      for (final path in ['../outside.md', '/etc/passwd', 'a/../../x']) {
        final r = await run('write_file', {'path': path, 'content': 'hi'});
        expect(r['error'], contains('inside your folder'), reason: path);
      }
      expect(File(p.join(dir.path, 'outside.md')).existsSync(), isFalse);
    });

    test('a symlink out of the folder is refused', () async {
      final outside = await Directory(p.join(dir.path, 'outside')).create();
      await Link(
        p.join(settings.companionFolder!, 'door'),
      ).create(outside.path);
      final r = await run('write_file', {'path': 'door/x.md', 'content': 'hi'});
      expect(r['error'], contains('inside your folder'));
      expect(File(p.join(outside.path, 'x.md')).existsSync(), isFalse);
    });

    test('core.md is the human\'s', () async {
      await File(
        p.join(settings.companionFolder!, 'core.md'),
      ).writeAsString('rules');
      final r = await run('write_file', {'path': 'core.md', 'content': 'mine'});
      expect(r['error'], contains('only they edit it'));
    });

    test('protected files can\'t be reached by another spelling', () async {
      await File(
        p.join(settings.companionFolder!, 'core.md'),
      ).writeAsString('rules');
      for (final path in ['CORE.md', 'core.md.', 'Core.MD ', 'core.md:x']) {
        final r = await run('write_file', {'path': path, 'content': 'mine'});
        expect(r['ok'], false, reason: path);
      }
      // A differently cased lessons.md is still checked like lessons.md.
      final r = await run('write_file', {
        'path': 'LESSONS.md',
        'content': '- not a lesson',
      });
      expect(r['error'], contains('Each lesson is one line'));
    });

    test('only text files are written', () async {
      for (final path in ['run.bat', 'x.sh', 'images/me.png', 'a.desktop']) {
        final r = await run('write_file', {'path': path, 'content': 'echo'});
        expect(r['error'], contains('Only text files'), reason: path);
      }
    });

    test('picture lines only reach pictures inside the folder', () {
      final folder = settings.companionFolder!;
      expect(
        Pictures.fileIn(folder, 'images/a.png')!.path,
        p.join(folder, 'images', 'a.png'),
      );
      for (final rel in ['../x.png', 'files/run.bat', 'a/../../x.jpg']) {
        expect(Pictures.fileIn(folder, rel), isNull, reason: rel);
      }
    });

    test('reads files and lists folders; writes new notes', () async {
      var r = await run('write_file', {
        'path': 'notes/today.md',
        'content': 'hello',
      });
      expect(r['ok'], true);
      r = await run('read_file', {'path': '.'});
      expect(
        r['entries'],
        containsAll(['lessons.md', 'notes/', 'personality.md', 'privacy.md']),
      );
      r = await run('read_file', {'path': 'notes/today.md'});
      expect(r['content'], 'hello');
      r = await run('edit_file', {
        'path': 'notes/today.md',
        'old_text': 'l',
        'new_text': 'L',
      });
      expect(r['error'], contains('2 times'));
    });
  });

  group('background', () {
    test('set_background takes colours, a layout and an accent', () async {
      final r = await run('set_background', {
        'colors': ['#ff0000', '00FF00'],
        'layout': 0.5,
      });
      expect(r['ok'], true, reason: '$r');
      expect(savedLook!.colors, [0xFFFF0000, 0xFF00FF00]);
      expect(savedLook!.layout, 0.5);
      expect(savedLook!.accent, isNull);

      await run('set_background', {'accent': '#B18CFF'});
      expect(savedLook!.accent, 0xFFB18CFF);
      expect(savedLook!.colors, isNull);
    });

    test('set_background refuses what is not a colour', () async {
      var r = await run('set_background', {
        'colors': ['red'],
      });
      expect(r['error'], contains('not a colour'));
      r = await run('set_background', {
        'colors': ['#111111', '#222222', '#333333', '#444444'],
      });
      expect(r['error'], contains('one to three'));
      r = await run('set_background', {'layout': 3});
      expect(r['error'], contains('0 to 1'));
      r = await run('set_background', {});
      expect(r['error'], contains('nothing'));
      expect(savedLook, isNull);
    });
  });

  group('theme', () {
    test('set_theme switches light, dark or back to system', () async {
      var r = await run('set_theme', {'theme': 'light'});
      expect(r['ok'], true, reason: '$r');
      expect(savedTheme, ThemeChoice.light);
      r = await run('set_theme', {'theme': 'system'});
      expect(r['theme'], 'system');
      expect(savedTheme, ThemeChoice.system);
    });

    test('set_theme refuses anything else', () async {
      final r = await run('set_theme', {'theme': 'sepia'});
      expect(r['error'], contains('light, dark or system'));
      expect(savedTheme, isNull);
    });
  });
}
