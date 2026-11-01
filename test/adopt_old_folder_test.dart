import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('adopt'));
  tearDown(() => root.deleteSync(recursive: true));

  test('moves the old folder over and fixes paths in settings', () async {
    final old = Directory(p.join(root.path, 'com.nucume.companion'))
      ..createSync();
    File(
      p.join(old.path, 'settings.json'),
    ).writeAsStringSync('{"modelsFolder":"${old.path}/models"}');
    File(p.join(old.path, 'companion.db')).writeAsStringSync('db');
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));

    await AppServices.adoptOldFolder(dir, old);

    expect(old.existsSync(), isFalse);
    expect(File(p.join(dir.path, 'companion.db')).existsSync(), isTrue);
    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      contains('${dir.path}/models'),
    );
  });

  test('leaves the old folder alone when the new one has settings', () async {
    final old = Directory(p.join(root.path, 'com.nucume.companion'))
      ..createSync();
    File(p.join(old.path, 'settings.json')).writeAsStringSync('{}');
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'))
      ..createSync();
    File(p.join(dir.path, 'settings.json')).writeAsStringSync('{"new":1}');

    await AppServices.adoptOldFolder(dir, old);

    expect(old.existsSync(), isTrue);
    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      '{"new":1}',
    );
  });

  test('looks for the old app id beside the new folder, not itself', () {
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));
    final old = AppServices.oldFolderFor(dir, windows: false);
    expect(p.basename(old.path), 'com.nucume.companion');
    expect(p.equals(old.parent.path, root.path), isTrue);
  });

  test('on Windows looks in com.nucume\\companion', () {
    final dir = Directory(p.join(root.path, 'Nucume', 'VoxCordis'));
    final old = AppServices.oldFolderFor(dir, windows: true);
    expect(
      p.equals(old.path, p.join(root.path, 'com.nucume', 'companion')),
      isTrue,
    );
  });

  test('fixes paths written with JSON escapes', () async {
    final old = Directory(p.join(root.path, 'com.nucume.companion'))
      ..createSync();
    final escaped = jsonEncode('${old.path}/models');
    File(
      p.join(old.path, 'settings.json'),
    ).writeAsStringSync('{"modelsFolder":$escaped}');
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));

    await AppServices.adoptOldFolder(dir, old);

    final settings =
        jsonDecode(File(p.join(dir.path, 'settings.json')).readAsStringSync())
            as Map<String, Object?>;
    expect(settings['modelsFolder'], '${dir.path}/models');
  });

  test('does nothing when the old folder is the new one', () async {
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'))
      ..createSync();
    File(p.join(dir.path, 'companion.db')).writeAsStringSync('db');

    await AppServices.adoptOldFolder(dir, dir);

    expect(File(p.join(dir.path, 'companion.db')).existsSync(), isTrue);
  });
}
