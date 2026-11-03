import 'dart:io';

import 'package:companion/services/system/older_copy.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for GTK's side of a running 0.3.7.
class _OldApp extends DBusObject {
  _OldApp() : super(DBusObjectPath('/com/nucume/companion'));

  var activated = 0;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.freedesktop.Application' &&
        methodCall.name == 'Activate') {
      activated++;
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  Process? daemon;
  DBusAddress? address;
  setUpAll(() async {
    try {
      daemon = await Process.start('dbus-daemon', [
        '--session',
        '--nofork',
        '--print-address',
      ]);
      final line = await daemon!.stdout
          .transform(const SystemEncoding().decoder)
          .first;
      address = DBusAddress(line.trim().split('\n').first);
    } on ProcessException {
      daemon = null;
    }
  });
  tearDownAll(() => daemon?.kill());

  test('none running', () async {
    if (address == null) return markTestSkipped('no dbus-daemon');
    expect(await OlderCopy.showIfRunning(address: address), isFalse);
  });

  test('one running is asked to show its window', () async {
    if (address == null) return markTestSkipped('no dbus-daemon');
    final old = DBusClient(address!);
    addTearDown(old.close);
    final app = _OldApp();
    await old.requestName(OlderCopy.appId);
    await old.registerObject(app);

    expect(
      await OlderCopy.showIfRunning(address: address, settle: Duration.zero),
      isTrue,
    );
    expect(app.activated, 1);
  });

  test('one quitting after starting this one does not count', () async {
    if (address == null) return markTestSkipped('no dbus-daemon');
    final old = DBusClient(address!);
    await old.requestName(OlderCopy.appId);
    final quitting = Future<void>.delayed(
      const Duration(milliseconds: 50),
      old.close,
    );

    expect(
      await OlderCopy.showIfRunning(
        address: address,
        settle: const Duration(milliseconds: 500),
      ),
      isFalse,
    );
    await quitting;
  });

  test('no bus to ask counts as none running', () async {
    final missing = Directory.systemTemp.createTempSync('nobus');
    addTearDown(() => missing.deleteSync(recursive: true));
    final address = DBusAddress.unix(path: '${missing.path}/bus');

    expect(await OlderCopy.showIfRunning(address: address), isFalse);
  });
}
