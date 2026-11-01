import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'desktop_notifier.dart';

/// Showing a file in the computer's file manager, and putting one in the
/// trash, the way the desktop does it.
class FileActions {
  const FileActions._();

  /// Opens the folder holding [file] with the file picked out where the
  /// file manager can (Explorer, Finder, and Linux file managers that
  /// answer org.freedesktop.FileManager1); otherwise just the folder.
  static Future<void> showInFolder(File file) async {
    final path = file.absolute.path;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', path]);
        return;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', ['-R', path]);
        if (r.exitCode == 0) return;
      } else if (Platform.isLinux) {
        final r = await Process.run('gdbus', [
          'call',
          '--session',
          '--dest',
          'org.freedesktop.FileManager1',
          '--object-path',
          '/org/freedesktop/FileManager1',
          '--method',
          'org.freedesktop.FileManager1.ShowItems',
          '[${DesktopNotifier.gvariantString(Uri.file(path).toString())}]',
          '""',
        ]);
        if (r.exitCode == 0) return;
      }
    } on ProcessException {
      // Fall back to the folder alone.
    }
    await launchUrl(Uri.directory(p.dirname(path)));
  }

  /// Moves [file] to the trash (the Recycle Bin on Windows) so a slip can
  /// be undone there; deletes it outright when there is no trash to use.
  static Future<void> trash(File file) async {
    final path = file.absolute.path;
    try {
      final ProcessResult r;
      if (Platform.isLinux) {
        r = await Process.run('gio', ['trash', '--', path]);
      } else if (Platform.isWindows) {
        r = await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Add-Type -AssemblyName Microsoft.VisualBasic; '
                '[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('
                '\$env:VC_TRASH, \'OnlyErrorDialogs\', \'SendToRecycleBin\')',
          ],
          environment: {'VC_TRASH': path},
        );
      } else if (Platform.isMacOS) {
        r = await Process.run('osascript', [
          '-e',
          'on run argv\n'
              'tell application "Finder" to delete POSIX file (item 1 of argv)\n'
              'end run',
          path,
        ]);
      } else {
        r = ProcessResult(0, 1, '', '');
      }
      if (r.exitCode == 0 && !await file.exists()) return;
    } on ProcessException {
      // No trash helper here.
    }
    if (await file.exists()) await file.delete();
  }
}
