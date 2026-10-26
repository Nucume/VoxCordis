import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../theme/app_theme.dart';

/// The VoxCordis icon in the system tray, with Open and Quit.
///
/// Windows: the runner adds the icon itself (windows/runner) and talks over
/// the `voxcordis/tray` channel. Linux: a StatusNotifierItem over D-Bus,
/// which KDE, Cinnamon, XFCE, Budgie and GNOME with the AppIndicator
/// extension show; no extra library is needed. Without a tray to show it
/// in, [show] returns false and closing the window minimises it instead.
abstract class Tray {
  static Tray? forPlatform({
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  }) {
    if (Platform.isWindows) return _WindowsTray(onOpen, onQuit);
    if (Platform.isLinux) return _LinuxTray(onOpen, onQuit);
    return null;
  }

  /// The Linux tray on the bus at [address], for tests.
  @visibleForTesting
  static Tray linux({
    required VoidCallback onOpen,
    required VoidCallback onQuit,
    DBusAddress? address,
  }) => _LinuxTray(onOpen, onQuit, address: address);

  /// Puts the icon in the tray. False when there is no tray to put it in.
  Future<bool> show();

  Future<void> hide();
}

class _WindowsTray implements Tray {
  _WindowsTray(VoidCallback onOpen, VoidCallback onQuit) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'open':
          onOpen();
        case 'quit':
          onQuit();
      }
    });
  }

  static const _channel = MethodChannel('voxcordis/tray');

  @override
  Future<bool> show() async {
    try {
      return await _channel.invokeMethod<bool>('show') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } on Object {
      // Nothing to take away.
    }
  }
}

class _LinuxTray implements Tray {
  _LinuxTray(this.onOpen, this.onQuit, {this.address});

  final VoidCallback onOpen;
  final VoidCallback onQuit;
  final DBusAddress? address;

  DBusClient? _client;

  @override
  Future<bool> show() async {
    if (_client != null) return true;
    DBusClient? client;
    try {
      client = address == null ? DBusClient.session() : DBusClient(address!);
      final name = 'org.kde.StatusNotifierItem-$pid-1';
      await client.requestName(name);
      await client.registerObject(
        StatusNotifierItem(icon: await _iconPixmaps(), onActivate: onOpen),
      );
      await client.registerObject(TrayMenu(onOpen: onOpen, onQuit: onQuit));
      await client.callMethod(
        destination: 'org.kde.StatusNotifierWatcher',
        path: DBusObjectPath('/StatusNotifierWatcher'),
        interface: 'org.kde.StatusNotifierWatcher',
        name: 'RegisterStatusNotifierItem',
        values: [DBusString(name)],
        replySignature: DBusSignature(''),
      );
      _client = client;
      return true;
    } on Object catch (e) {
      debugPrint('No system tray: $e');
      await client?.close();
      return false;
    }
  }

  @override
  Future<void> hide() async {
    final client = _client;
    _client = null;
    // Leaving the bus takes the icon away.
    await client?.close();
  }

  /// The app icon at two sizes, as ARGB32 in network byte order.
  static Future<List<(int, int, Uint8List)>> _iconPixmaps() async {
    try {
      final data = await rootBundle.load(AppTheme.appIcon);
      final source = img.decodePng(data.buffer.asUint8List());
      if (source == null) return const [];
      return [
        for (final size in [32, 64])
          _argb(
            img.copyResize(
              source,
              width: size,
              height: size,
              interpolation: img.Interpolation.average,
            ),
          ),
      ];
    } on Object {
      return const [];
    }
  }

  static (int, int, Uint8List) _argb(img.Image image) {
    final rgba = image.convert(numChannels: 4);
    final out = Uint8List(rgba.width * rgba.height * 4);
    var i = 0;
    for (final p in rgba) {
      out[i++] = p.a.toInt();
      out[i++] = p.r.toInt();
      out[i++] = p.g.toInt();
      out[i++] = p.b.toInt();
    }
    return (rgba.width, rgba.height, out);
  }
}

/// org.kde.StatusNotifierItem: the icon itself. A click opens the window;
/// the menu comes from [TrayMenu].
@visibleForTesting
class StatusNotifierItem extends DBusObject {
  StatusNotifierItem({required this.icon, required this.onActivate})
    : super(DBusObjectPath('/StatusNotifierItem'));

  final List<(int, int, Uint8List)> icon;
  final VoidCallback onActivate;

  static const _interface = 'org.kde.StatusNotifierItem';

  static DBusValue _pixmaps(List<(int, int, Uint8List)> icons) =>
      DBusArray(DBusSignature('(iiay)'), [
        for (final (w, h, bytes) in icons)
          DBusStruct([DBusInt32(w), DBusInt32(h), DBusArray.byte(bytes)]),
      ]);

  Map<String, DBusValue> get _properties => {
    'Category': const DBusString('ApplicationStatus'),
    'Id': const DBusString('voxcordis'),
    'Title': const DBusString('VoxCordis'),
    'Status': const DBusString('Active'),
    'WindowId': const DBusInt32(0),
    // A themed icon when the package installed one; the pixels otherwise.
    'IconName': const DBusString('com.nucume.companion'),
    'IconThemePath': const DBusString(''),
    'IconPixmap': _pixmaps(icon),
    'OverlayIconName': const DBusString(''),
    'OverlayIconPixmap': _pixmaps(const []),
    'AttentionIconName': const DBusString(''),
    'AttentionIconPixmap': _pixmaps(const []),
    'AttentionMovieName': const DBusString(''),
    'ToolTip': DBusStruct([
      const DBusString(''),
      _pixmaps(const []),
      const DBusString('VoxCordis'),
      const DBusString(''),
    ]),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath('/MenuBar'),
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final call = methodCall;
    if (call.interface != _interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Activate':
      case 'SecondaryActivate':
        onActivate();
        return DBusMethodSuccessResponse();
      case 'ContextMenu':
      case 'Scroll':
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == _interface ? _properties[name] : null;
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == _interface ? _properties : const {},
      );
}

/// com.canonical.dbusmenu: Open VoxCordis, a line, Quit VoxCordis.
@visibleForTesting
class TrayMenu extends DBusObject {
  TrayMenu({required this.onOpen, required this.onQuit})
    : super(DBusObjectPath('/MenuBar'));

  final VoidCallback onOpen;
  final VoidCallback onQuit;

  static const _interface = 'com.canonical.dbusmenu';
  static const openId = 1;
  static const quitId = 3;

  static Map<int, Map<String, DBusValue>> get _items => {
    0: {'children-display': const DBusString('submenu')},
    openId: {'label': const DBusString('Open VoxCordis')},
    2: {'type': const DBusString('separator')},
    quitId: {'label': const DBusString('Quit VoxCordis')},
  };

  static DBusStruct _layout(int id) => DBusStruct([
    DBusInt32(id),
    DBusDict.stringVariant(_items[id]!),
    DBusArray.variant([
      if (id == 0)
        for (final child in [openId, 2, quitId]) _layout(child),
    ]),
  ]);

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final call = methodCall;
    if (call.interface != _interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final args = call.values;
    switch (call.name) {
      case 'GetLayout':
        final id = args[0].asInt32();
        if (!_items.containsKey(id)) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        return DBusMethodSuccessResponse([const DBusUint32(1), _layout(id)]);
      case 'GetGroupProperties':
        final ids = args[0].asInt32Array();
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in ids.isEmpty ? _items.keys : ids)
              if (_items[id] case final props?)
                DBusStruct([DBusInt32(id), DBusDict.stringVariant(props)]),
          ]),
        ]);
      case 'GetProperty':
        final value = _items[args[0].asInt32()]?[args[1].asString()];
        if (value == null) return DBusMethodErrorResponse.invalidArgs();
        return DBusMethodSuccessResponse([DBusVariant(value)]);
      case 'Event':
        _event(args[0].asInt32(), args[1].asString());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        for (final e in args[0].asArray()) {
          final s = e.asStruct();
          _event(s[0].asInt32(), s[1].asString());
        }
        return DBusMethodSuccessResponse([DBusArray.int32(const [])]);
      case 'AboutToShow':
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return DBusMethodSuccessResponse([
          DBusArray.int32(const []),
          DBusArray.int32(const []),
        ]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  void _event(int id, String event) {
    if (event != 'clicked') return;
    if (id == openId) onOpen();
    if (id == quitId) onQuit();
  }

  Map<String, DBusValue> get _properties => {
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string(const []),
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == _interface ? _properties[name] : null;
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == _interface ? _properties : const {},
      );
}
