import 'dart:convert';
import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/system/system_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late AppSettings settings;
  late SystemTools tools;
  late List<SystemRequest> asked;
  late SystemApproval answer;
  late List<Uri> opened;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('system');
    await Directory(p.join(dir.path, 'Mira')).create();
    settings = AppSettings(
      companionFolder: p.join(dir.path, 'Mira'),
      systemAccess: true,
    );
    asked = [];
    answer = SystemApproval.once;
    opened = [];
    tools =
        SystemTools(
            settings: () => settings,
            logFile: File(p.join(dir.path, 'system-access.log')),
            allowAlways: (key) async => settings = settings.copyWith(
              allowedSystemActions: [...settings.allowedSystemActions, key],
            ),
            launcher: (uri) async {
              opened.add(uri);
              return true;
            },
          )
          ..ask = (r) async {
            asked.add(r);
            return answer;
          };
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Map<String, Object?>> run(
    String name,
    Map<String, Object?> args,
  ) async => jsonDecode(await tools.call(name, args)) as Map<String, Object?>;

  String log() =>
      File(p.join(dir.path, 'system-access.log')).readAsStringSync();

  test('the tools are only offered while system access is on', () {
    String names(AppSettings s) => [
      for (final t in ChatController.toolsFor(s))
        (t['function'] as Map)['name'],
    ].join(',');
    expect(names(const AppSettings()), isNot(contains('run_command')));
    expect(names(settings), contains('run_command'));
  });

  test('nothing runs while system access is off', () async {
    settings = settings.copyWith(systemAccess: false);
    final r = await run('run_command', {'command': 'echo hi', 'why': 'test'});
    expect(r['error'], contains('off'));
    expect(asked, isEmpty);
  });

  test('a command runs in the companion folder after an OK', () async {
    final r = await run('run_command', {
      'command': Platform.isWindows ? 'Get-Location' : 'pwd',
      'why': 'see where I am',
    });
    expect(asked.single.target, Platform.isWindows ? 'Get-Location' : 'pwd');
    expect(asked.single.why, 'see where I am');
    expect(r['ok'], true);
    expect(r['output'], contains('Mira'));
    expect(log(), contains('ran, exit 0'));
  }, testOn: '!windows');

  test('a refusal runs nothing and is logged', () async {
    answer = SystemApproval.deny;
    final marker = p.join(dir.path, 'made');
    final r = await run('run_command', {'command': 'touch $marker', 'why': ''});
    expect(r['ok'], false);
    expect(r['error'], contains('said no'));
    expect(File(marker).existsSync(), isFalse);
    expect(log(), contains('denied'));
  });

  test('"always" skips asking for that exact command only', () async {
    answer = SystemApproval.always;
    await run('run_command', {'command': 'echo one', 'why': ''});
    expect(settings.allowedSystemActions, ['run: echo one']);
    answer = SystemApproval.deny;
    final again = await run('run_command', {'command': 'echo one', 'why': ''});
    expect(again['ok'], true);
    expect(asked, hasLength(1));
    final other = await run('run_command', {
      'command': 'echo one; echo two',
      'why': '',
    });
    expect(other['ok'], false);
    expect(asked, hasLength(2));
  }, testOn: '!windows');

  test('a command that runs too long is stopped', () async {
    tools = SystemTools(
      settings: () => settings,
      logFile: File(p.join(dir.path, 'system-access.log')),
      allowAlways: (_) async {},
      timeout: const Duration(milliseconds: 300),
    )..ask = (_) async => SystemApproval.once;
    final r = await run('run_command', {'command': 'sleep 5', 'why': ''});
    expect(r['ok'], false);
    expect(r['error'], contains('Stopped'));
  }, testOn: '!windows');

  test('open takes web addresses, and paths from the folder or home', () async {
    await File(p.join(dir.path, 'Mira', 'notes.md')).writeAsString('hi');
    var r = await run('open', {'target': 'https://example.com', 'why': ''});
    expect(r['ok'], true);
    r = await run('open', {'target': 'notes.md', 'why': ''});
    expect(r['ok'], true);
    expect(opened.last, Uri.file(p.join(dir.path, 'Mira', 'notes.md')));
    r = await run('open', {'target': 'missing.md', 'why': ''});
    expect(r['error'], contains('does not exist'));
    expect(
      (await SystemTools.resolveTarget('~', null)).toFilePath(),
      startsWith(homeDirForTest()),
    );
  });

  test('usual folders open by name, wherever the system keeps them', () async {
    // Like Pictures kept in OneDrive on Windows, or "Bilder" on Linux.
    final pictures = await Directory(
      p.join(dir.path, 'OneDrive', 'Bilder'),
    ).create(recursive: true);
    await Directory(p.join(pictures.path, 'Screenshots')).create();
    Future<String?> known(String name) async =>
        name.toLowerCase() == 'pictures' ? pictures.path : null;
    for (final target in [
      'Pictures',
      'pictures',
      '~/Pictures',
      r'~\Pictures',
      'Pictures/',
    ]) {
      final uri = await SystemTools.resolveTarget(
        target,
        settings.companionFolder,
        knownFolder: known,
      );
      expect(uri, Uri.directory(pictures.path), reason: target);
    }
    expect(
      await SystemTools.resolveTarget(
        '~/Pictures/Screenshots',
        settings.companionFolder,
        knownFolder: known,
      ),
      Uri.directory(p.join(pictures.path, 'Screenshots')),
    );
    // The companion's own folder comes first.
    final own = await Directory(
      p.join(settings.companionFolder!, 'Pictures'),
    ).create();
    expect(
      await SystemTools.resolveTarget(
        'Pictures',
        settings.companionFolder,
        knownFolder: known,
      ),
      Uri.directory(own.path),
    );
  });

  test('the usual folder names map to the system\'s folders', () async {
    expect(await SystemTools.userFolder('Home'), homeDirForTest());
    expect(await SystemTools.userFolder('My Pictures'), isNotNull);
    expect(await SystemTools.userFolder('Photos'), isNotNull);
    expect(await SystemTools.userFolder('images'), isNull);
  });

  test('without an approval dialog every request is refused', () async {
    tools.ask = null;
    final r = await run('open', {'target': 'https://example.com', 'why': ''});
    expect(r['ok'], false);
    expect(opened, isEmpty);
  });

  test('a program or script is asked about every time', () async {
    final script = File(p.join(dir.path, 'Mira', 'tidy.bat.'));
    await script.writeAsString('del /q *');
    settings = settings.copyWith(allowedSystemActions: ['open: tidy.bat.']);
    answer = SystemApproval.always;
    await run('open', {'target': 'tidy.bat.', 'why': 'tidy up'});
    expect(asked.single.runnable, isTrue);
    // "Always" is not kept for it either.
    expect(settings.allowedSystemActions, ['open: tidy.bat.']);
    await run('open', {'target': 'tidy.bat.', 'why': 'tidy up'});
    expect(asked, hasLength(2));
  });

  test('runnable files are recognized the way the OS sees them', () {
    expect(SystemTools.isRunnable('x.EXE'), isTrue);
    expect(SystemTools.isRunnable('x.exe . '), isTrue);
    expect(SystemTools.isRunnable('notes/today.md'), isFalse);
    expect(SystemTools.isRunnable('https://example.com'), isFalse);
  });

  test('an executable without an extension is runnable', () async {
    final f = File(p.join(dir.path, 'Mira', 'tool'));
    await f.writeAsString('#!/bin/sh\n');
    await Process.run('chmod', ['755', f.path]);
    expect(SystemTools.isRunnable(f.path), isTrue);
  }, skip: Platform.isWindows);
}

String homeDirForTest() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!;
