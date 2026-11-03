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

  Directory oldWithData() {
    final old = Directory(p.join(root.path, 'com.nucume.companion'))
      ..createSync();
    File(p.join(old.path, 'settings.json')).writeAsStringSync('{}');
    File(p.join(old.path, 'companion.db')).writeAsStringSync('db');
    Directory(p.join(old.path, 'secrets')).createSync();
    File(p.join(old.path, 'secrets', 'key')).writeAsStringSync('k');
    return old;
  }

  test('moves nothing while an older copy is still running', () async {
    final old = oldWithData();
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));

    final adopted = await AppServices.adoptOldFolder(
      dir,
      old,
      olderCopyRunning: () async => true,
    );

    expect(adopted, isFalse);
    expect(File(p.join(old.path, 'settings.json')).existsSync(), isTrue);
    expect(File(p.join(old.path, 'companion.db')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'settings.json')).existsSync(), isFalse);
  });

  test('moves as usual when no older copy is running', () async {
    final old = oldWithData();
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));

    final adopted = await AppServices.adoptOldFolder(
      dir,
      old,
      olderCopyRunning: () async => false,
    );

    expect(adopted, isTrue);
    expect(old.existsSync(), isFalse);
    expect(File(p.join(dir.path, 'settings.json')).existsSync(), isTrue);
  });

  test('copies what cannot be renamed onto another drive', () async {
    final old = oldWithData();
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));
    final otherDrive = Platform.isWindows ? 17 : 18;

    await AppServices.adoptOldFolder(
      dir,
      old,
      rename: (e, to) async => throw FileSystemException(
        'Rename failed',
        e.path,
        OSError('Invalid cross-device link', otherDrive),
      ),
    );

    expect(File(p.join(dir.path, 'settings.json')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'companion.db')).readAsStringSync(), 'db');
    expect(File(p.join(dir.path, 'secrets', 'key')).readAsStringSync(), 'k');
    expect(old.existsSync(), isFalse);
    expect(dir.listSync().where((e) => e.path.endsWith('.moving')), isEmpty);
  });

  test('moves settings anyway and finishes the rest next time', () async {
    final old = oldWithData();
    File(
      p.join(old.path, 'settings.json'),
    ).writeAsStringSync('{"mine":true,"folder":"${old.path}/secrets"}');
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));
    final pending = File(p.join(dir.path, AppServices.pendingFile));

    // secrets is in use this time.
    await AppServices.adoptOldFolder(
      dir,
      old,
      rename: (e, to) async {
        if (p.basename(e.path) == 'secrets') {
          throw FileSystemException('Rename failed', e.path);
        }
        await e.rename(to);
      },
    );

    expect(File(p.join(dir.path, 'companion.db')).existsSync(), isTrue);
    expect(File(p.join(old.path, 'secrets', 'key')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'settings.json')).existsSync(), isTrue);
    expect(pending.readAsLinesSync(), ['secrets']);

    // The app saves its settings meanwhile.
    final settings = File(p.join(dir.path, 'settings.json'));
    settings.writeAsStringSync(
      settings.readAsStringSync().replaceFirst('}', ',"saved":1}'),
    );

    // The next start finishes the move.
    await AppServices.adoptOldFolder(dir, old);

    expect(File(p.join(dir.path, 'secrets', 'key')).readAsStringSync(), 'k');
    expect(old.existsSync(), isFalse);
    expect(pending.existsSync(), isFalse);
    final json = jsonDecode(settings.readAsStringSync()) as Map;
    expect(json['mine'], isTrue);
    expect(json['saved'], 1);
    expect(json['folder'], '${dir.path}/secrets');
  });

  test('stops trying what is already in the new folder', () async {
    final old = oldWithData();
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));
    final pending = File(p.join(dir.path, AppServices.pendingFile));
    await AppServices.adoptOldFolder(
      dir,
      old,
      rename: (e, to) async {
        if (p.basename(e.path) == 'secrets') {
          throw FileSystemException('Rename failed', e.path);
        }
        await e.rename(to);
      },
    );
    expect(pending.existsSync(), isTrue);

    // Made afresh in the new folder before the next start.
    Directory(p.join(dir.path, 'secrets')).createSync();
    await AppServices.adoptOldFolder(dir, old);

    expect(pending.existsSync(), isFalse);
    expect(File(p.join(old.path, 'secrets', 'key')).existsSync(), isTrue);
  });

  test('forgets what was left once the old folder is gone', () async {
    final old = Directory(p.join(root.path, 'com.nucume.companion'));
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'))
      ..createSync();
    final pending = File(p.join(dir.path, AppServices.pendingFile))
      ..writeAsStringSync('secrets\n');

    await AppServices.adoptOldFolder(dir, old);

    expect(pending.existsSync(), isFalse);
  });

  test('still moves settings after a start cut short before it', () async {
    final old = oldWithData();
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'))
      ..createSync();
    // The list of what was left is written, then the app stopped before
    // settings.json moved.
    final pending = File(p.join(dir.path, AppServices.pendingFile))
      ..writeAsStringSync('secrets\n');
    File(p.join(old.path, 'settings.json')).writeAsStringSync('{"mine":1}');

    await AppServices.adoptOldFolder(dir, old);

    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      contains('"mine"'),
    );
    expect(pending.existsSync(), isFalse);
  });

  test('copies settings that cannot be moved', () async {
    final old = oldWithData();
    File(p.join(old.path, 'settings.json')).writeAsStringSync('{"mine":1}');
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));

    await AppServices.adoptOldFolder(
      dir,
      old,
      rename: (e, to) async {
        if (p.basename(e.path) == 'settings.json') {
          throw FileSystemException('In use', e.path);
        }
        await e.rename(to);
      },
    );

    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      contains('"mine"'),
    );
    expect(File(p.join(old.path, 'settings.json')).existsSync(), isFalse);
  });

  test('leaves what does not fit, without trying it every start', () async {
    final old = oldWithData();
    Directory(p.join(old.path, 'models')).createSync();
    File(
      p.join(old.path, 'settings.json'),
    ).writeAsStringSync('{"modelsFolder":"${old.path}/models"}');
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));
    final noSpace = Platform.isWindows ? 112 : 28;

    await AppServices.adoptOldFolder(
      dir,
      old,
      rename: (e, to) async {
        if (p.basename(e.path) == 'models') {
          throw FileSystemException(
            'Rename failed',
            e.path,
            OSError('No space left on device', noSpace),
          );
        }
        await e.rename(to);
      },
    );

    expect(Directory(p.join(old.path, 'models')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'companion.db')).existsSync(), isTrue);
    expect(
      File(p.join(dir.path, AppServices.pendingFile)).existsSync(),
      isFalse,
    );
    // Still pointing where the models are.
    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      contains('${old.path}/models'),
    );
  });

  test('a linked entry stays a link on another drive', () async {
    final old = oldWithData();
    final big = Directory(p.join(root.path, 'big'))..createSync();
    File(p.join(big.path, 'model.gguf')).writeAsStringSync('weights');
    Link(p.join(old.path, 'models')).createSync(big.path);
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'));
    final otherDrive = Platform.isWindows ? 17 : 18;

    await AppServices.adoptOldFolder(
      dir,
      old,
      rename: (e, to) async => throw FileSystemException(
        'Rename failed',
        e.path,
        OSError('Invalid cross-device link', otherDrive),
      ),
    );

    final models = p.join(dir.path, 'models');
    expect(FileSystemEntity.isLinkSync(models), isTrue);
    expect(p.equals(Link(models).targetSync(), big.path), isTrue);
    expect(File(p.join(big.path, 'model.gguf')).existsSync(), isTrue);
    expect(old.existsSync(), isFalse);
    // Links need extra rights on Windows.
  }, skip: Platform.isWindows);

  test('an old folder linked elsewhere is linked from the new name', () async {
    final elsewhere = Directory(p.join(root.path, 'data'))..createSync();
    File(p.join(elsewhere.path, 'settings.json')).writeAsStringSync(
      '{"modelsFolder":"${root.path}/com.nucume.companion/models"}',
    );
    File(p.join(elsewhere.path, 'companion.db')).writeAsStringSync('db');
    final old = Directory(p.join(root.path, 'com.nucume.companion'));
    Link(old.path).createSync(elsewhere.path);
    final dir = Directory(p.join(root.path, 'com.nucume.voxcordis'))
      ..createSync();

    await AppServices.adoptOldFolder(dir, old);

    expect(FileSystemEntity.isLinkSync(old.path), isFalse);
    expect(old.existsSync(), isFalse);
    expect(
      p.equals(
        dir.resolveSymbolicLinksSync(),
        elsewhere.resolveSymbolicLinksSync(),
      ),
      isTrue,
    );
    expect(File(p.join(elsewhere.path, 'companion.db')).existsSync(), isTrue);
    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      contains('${dir.path}/models'),
    );
    // Links need extra rights on Windows.
  }, skip: Platform.isWindows);
}
