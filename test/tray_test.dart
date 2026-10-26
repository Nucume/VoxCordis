import 'dart:io';

import 'package:companion/services/system/tray.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the desktop's tray host.
class _Watcher extends DBusObject {
  _Watcher() : super(DBusObjectPath('/StatusNotifierWatcher'));

  final registered = <String>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name == 'RegisterStatusNotifierItem') {
      registered.add(methodCall.values.first.asString());
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('without a tray host it says so', () async {
    if (address == null) return markTestSkipped('no dbus-daemon');
    final tray = Tray.linux(onOpen: () {}, onQuit: () {}, address: address);
    expect(await tray.show(), isFalse);
  });

  test('registers with the host, and its menu opens and quits', () async {
    if (address == null) return markTestSkipped('no dbus-daemon');
    final host = DBusClient(address!);
    final watcher = _Watcher();
    await host.requestName('org.kde.StatusNotifierWatcher');
    await host.registerObject(watcher);

    var opened = 0, quit = 0;
    final tray = Tray.linux(
      onOpen: () => opened++,
      onQuit: () => quit++,
      address: address,
    );
    expect(await tray.show(), isTrue);
    expect(
      watcher.registered.single,
      startsWith('org.kde.StatusNotifierItem-'),
    );
    final item = DBusRemoteObject(
      host,
      name: watcher.registered.single,
      path: DBusObjectPath('/StatusNotifierItem'),
    );
    final menuPath = await item.getProperty(
      'org.kde.StatusNotifierItem',
      'Menu',
    );
    final pixmaps = await item.getProperty(
      'org.kde.StatusNotifierItem',
      'IconPixmap',
    );
    expect(pixmaps.asArray(), hasLength(2));

    await item.callMethod('org.kde.StatusNotifierItem', 'Activate', [
      const DBusInt32(0),
      const DBusInt32(0),
    ]);
    expect(opened, 1);

    final menu = DBusRemoteObject(
      host,
      name: watcher.registered.single,
      path: menuPath.asObjectPath(),
    );
    final layout = await menu.callMethod(
      'com.canonical.dbusmenu',
      'GetLayout',
      [const DBusInt32(0), const DBusInt32(-1), DBusArray.string(const [])],
    );
    final children = layout.values[1].asStruct()[2].asArray();
    final labels = [
      for (final c in children)
        c.asVariant().asStruct()[1].asStringVariantDict()['label']?.asString(),
    ];
    expect(labels, ['Open VoxCordis', null, 'Quit VoxCordis']);

    await menu.callMethod('com.canonical.dbusmenu', 'Event', [
      const DBusInt32(TrayMenu.quitId),
      const DBusString('clicked'),
      DBusVariant(const DBusString('')),
      const DBusUint32(0),
    ]);
    expect(quit, 1);

    await tray.hide();
    await host.close();
  });
}
