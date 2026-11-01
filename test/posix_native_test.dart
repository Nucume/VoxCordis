import 'dart:io';

import 'package:companion/services/system/posix_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('reads a folder from user-dirs.dirs', () {
    final dir = Directory.systemTemp.createTempSync('vc_xdg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'user-dirs.dirs'))
      ..writeAsStringSync(
        '# comment\nXDG_DOWNLOAD_DIR="\$HOME/Got"\nXDG_MUSIC_DIR="/m/tunes"\n',
      );
    expect(
      PosixNative.xdgUserDir('DOWNLOAD', configFile: file.path, home: '/h'),
      '/h/Got',
    );
    expect(
      PosixNative.xdgUserDir('MUSIC', configFile: file.path, home: '/h'),
      '/m/tunes',
    );
    expect(
      PosixNative.xdgUserDir('VIDEOS', configFile: file.path, home: '/h'),
      isNull,
    );
  }, skip: Platform.isWindows);

  test('makes a file executable without the shell', () {
    final dir = Directory.systemTemp.createTempSync('vc_chmod');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File(p.join(dir.path, 'tool'))..writeAsStringSync('x');
    Process.runSync('chmod', ['644', f.path]);
    expect(PosixNative.makeExecutable(f.path), isTrue);
    expect(f.statSync().mode & 0x49, isNot(0));
  }, skip: Platform.isWindows);

  test('knows whether it runs as root', () {
    final id = Process.runSync('id', ['-u']).stdout.toString().trim();
    expect(PosixNative.isRoot(), id == '0');
  }, skip: Platform.isWindows);
}
