import 'dart:io';

import 'package:companion/shell/window_frame.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final calls = <MethodCall>[];
  setUp(() {
    dir = Directory.systemTemp.createTempSync('titlebar');
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    dir.deleteSync(recursive: true);
  });

  test('Linux shows the system bar when it was chosen', () async {
    File(p.join(dir.path, 'system-title-bar')).writeAsStringSync('1');

    await TitleBarChoice.load(dir);

    expect(TitleBarChoice.system.value, isTrue);
    final style = calls.where((c) => c.method == 'setTitleBarStyle');
    // The runner may not have seen the flag, on the first start after the
    // data folder moved, and hid the bar.
    expect(style.single.arguments, containsPair('titleBarStyle', 'normal'));
  }, skip: !Platform.isLinux);

  test('hides the system bar for VoxCordis\' own', () async {
    await TitleBarChoice.load(dir);

    expect(TitleBarChoice.system.value, isFalse);
    final style = calls.where((c) => c.method == 'setTitleBarStyle');
    expect(style.single.arguments, containsPair('titleBarStyle', 'hidden'));
  }, skip: !TitleBarChoice.supported);
}
