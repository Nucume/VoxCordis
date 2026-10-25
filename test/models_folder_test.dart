import 'dart:io';

import 'package:companion/services/folder_service.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('VoxCordisFolder', () {
    test('puts VoxCordis inside the chosen folder once', () {
      expect(VoxCordisFolder.inside('/data'), p.join('/data', 'VoxCordis'));
      expect(VoxCordisFolder.inside('/data/VoxCordis'), '/data/VoxCordis');
      expect(VoxCordisFolder.inside('/data/voxcordis'), '/data/voxcordis');
    });

    test('names the companion folder safely', () {
      const root = '/home/a/VoxCordis';
      expect(VoxCordisFolder.companion(root, 'Mira'), '$root/Mira');
      expect(VoxCordisFolder.companion(root, 'A/B: C?'), '$root/AB C');
      expect(VoxCordisFolder.companion(root, '..'), '$root/Companion');
      expect(
        VoxCordisFolder.companion(root, 'Models'),
        '$root/Models (companion)',
      );
      expect(VoxCordisFolder.models(root), '$root/models');
    });
  });

  test('forPath recognises a catalog file wherever it is', () {
    final m = ModelCatalog.models.first;
    final elsewhere = p.join('/mnt/big', p.posix.basename(m.file));
    expect(ModelCatalog.forPath(elsewhere), m);
    expect(ModelCatalog.forPath('/mnt/big/mine.gguf'), isNull);
  });

  group('moving the models folder', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('models'));
    tearDown(() => tmp.delete(recursive: true));

    test('moves every file and removes the empty old folder', () async {
      final from = Directory(p.join(tmp.path, 'old'))..createSync();
      final to = Directory(p.join(tmp.path, 'new', 'models'));
      File(p.join(from.path, 'a.gguf')).writeAsStringSync('A');
      File(p.join(from.path, 'b.gguf')).writeAsStringSync('B');
      final seen = <String>[];
      await ModelCatalog.moveFolder(
        from,
        to,
        onFile: (name, i, n) => seen.add('$name ${i + 1}/$n'),
      );
      expect(File(p.join(to.path, 'a.gguf')).readAsStringSync(), 'A');
      expect(File(p.join(to.path, 'b.gguf')).readAsStringSync(), 'B');
      expect(seen, hasLength(2));
      expect(from.existsSync(), isFalse);
    });

    test('never overwrites a file already there', () async {
      final from = Directory(p.join(tmp.path, 'old'))..createSync();
      final to = Directory(p.join(tmp.path, 'new'))..createSync();
      File(p.join(from.path, 'a.gguf')).writeAsStringSync('old');
      File(p.join(to.path, 'a.gguf')).writeAsStringSync('new');
      await ModelCatalog.moveFolder(from, to);
      expect(File(p.join(to.path, 'a.gguf')).readAsStringSync(), 'new');
      expect(File(p.join(from.path, 'a.gguf')).existsSync(), isTrue);
    });

    test('movedPath follows files inside the old folder only', () {
      final from = Directory('/x/models');
      final to = Directory('/y/VoxCordis/models');
      expect(
        ModelCatalog.movedPath('/x/models/a.gguf', from, to),
        '/y/VoxCordis/models/a.gguf',
      );
      expect(ModelCatalog.movedPath('/z/mine.gguf', from, to), '/z/mine.gguf');
      expect(ModelCatalog.movedPath(null, from, to), isNull);
    });
  });
}
