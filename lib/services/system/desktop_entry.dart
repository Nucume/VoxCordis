import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../theme/app_theme.dart';
import '../folder_service.dart';
import 'background.dart';

/// Linux: tells the desktop which icon is VoxCordis'. Wayland desktops
/// (KDE's Alt+Tab, the taskbar) find a window's icon only through a
/// .desktop file named after its app id; without one they show a generic
/// "W". An AppImage installs none, so VoxCordis writes its own entry and
/// icon into the user's data folder, which also puts it in the app menu.
/// Rewritten when it changes, e.g. after the AppImage moved.
class DesktopEntry {
  DesktopEntry._();

  static const appId = 'com.nucume.companion';

  static Future<void> install() async {
    if (!Platform.isLinux) return;
    try {
      final data =
          Platform.environment['XDG_DATA_HOME'] ??
          p.join(homeDir, '.local', 'share');
      final icon = File(
        p.join(data, 'icons', 'hicolor', '256x256', 'apps', '$appId.png'),
      );
      final bytes = (await rootBundle.load(
        AppTheme.appIcon,
      )).buffer.asUint8List();
      if (!await icon.exists() ||
          !listEquals(await icon.readAsBytes(), bytes)) {
        await icon.parent.create(recursive: true);
        await icon.writeAsBytes(bytes);
      }
      final entry = File(p.join(data, 'applications', '$appId.desktop'));
      final text = contents(Background.launchCommand);
      if (!await entry.exists() || await entry.readAsString() != text) {
        await entry.parent.create(recursive: true);
        await entry.writeAsString(text);
      }
    } on Object catch (e) {
      debugPrint('No desktop entry: $e');
    }
  }

  /// The .desktop file that starts [command].
  static String contents(String command) {
    final quoted = Background.quoteExec(command);
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=VoxCordis\n'
        'Comment=A private AI companion\n'
        'Exec=$quoted\n'
        'Icon=$appId\n'
        'StartupWMClass=$appId\n'
        'Categories=Utility;Chat;\n'
        'Terminal=false\n';
  }
}
