import 'dart:io';

import 'package:companion/services/import/import_temp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a used picture is removed, a kept one stays', () async {
    final used = await ImportTemp.create();
    final kept = await ImportTemp.create();
    final a = File(p.join(used.path, 'avatar.png'))..writeAsStringSync('x');
    final b = File(p.join(kept.path, 'avatar.png'))..writeAsStringSync('x');
    expect(ImportTemp.holds(a.path), isTrue);
    expect(ImportTemp.holds('/home/me/Pictures/me.png'), isFalse);

    await ImportTemp.remove(a.path);
    expect(used.existsSync(), isFalse);
    // Only its own folders: a picture the human chose stays put.
    await ImportTemp.remove(p.join(Directory.systemTemp.path, 'x', 'a.png'));

    // clearAll isn't run here: other test files import in parallel.
    expect(b.existsSync(), isTrue);
    await kept.delete(recursive: true);
  });
}
