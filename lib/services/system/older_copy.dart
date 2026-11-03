import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// VoxCordis 0.3.7 and older, which ran under another app id on Linux.
///
/// One copy at a time is kept by GTK, by app id. With the new id a new
/// copy no longer sees an old one that is still running (in the tray, say)
/// and would move the data folder out from under it.
abstract final class OlderCopy {
  static const appId = 'com.nucume.companion';

  /// Whether an older copy is running. If it is, it is asked to show its
  /// window, as a second launch used to do. Any trouble with the bus counts
  /// as not running, so starting is never held up for long.
  static Future<bool> showIfRunning({
    DBusAddress? address,
    Duration timeout = const Duration(seconds: 2),
    Duration settle = const Duration(seconds: 1),
  }) async {
    DBusClient? client;
    try {
      client = address == null ? DBusClient.session() : DBusClient(address);
      final bus = client;
      Future<bool> running() => bus.nameHasOwner(appId).timeout(timeout);
      if (!await running()) return false;
      // Started by the old copy's updater, which quits straight after: give
      // it a moment to go.
      await Future<void>.delayed(settle);
      if (!await running()) return false;
      try {
        // GTK answers this on the app's object path and brings the window
        // back, out of the tray too.
        await bus
            .callMethod(
              destination: appId,
              path: DBusObjectPath('/com/nucume/companion'),
              interface: 'org.freedesktop.Application',
              name: 'Activate',
              values: [DBusDict.stringVariant(const {})],
              replySignature: DBusSignature(''),
            )
            .timeout(timeout);
      } on Object catch (e) {
        // Still running: leave its data alone even if it did not answer.
        debugPrint('Older VoxCordis did not come forward: $e');
      }
      return true;
    } on Object catch (e) {
      debugPrint('Could not look for an older VoxCordis: $e');
      return false;
    } finally {
      // Not waited for: a bus that never answered may not close either.
      unawaited(client?.close().catchError((Object _) {}));
    }
  }
}
