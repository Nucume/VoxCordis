import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// The companion's folder on disk. The companion may read and write here and
/// nowhere else.
class CompanionFolder {
  CompanionFolder(this.root);

  final String root;

  static const subfolders = ['images', 'files', 'imported'];

  Directory get images => Directory(p.join(root, 'images'));

  Future<void> ensureExists() async {
    for (final sub in subfolders) {
      await Directory(p.join(root, sub)).create(recursive: true);
    }
  }

  /// Opens the folder in Explorer, Finder, Dolphin, Nautilus…
  Future<bool> openInFileManager() => launchUrl(Uri.directory(root));

  /// Resolves a path the model gave, refusing anything outside [root].
  String resolveInside(String relative) {
    final full = p.normalize(p.join(root, relative));
    if (!p.isWithin(root, full) && full != p.normalize(root)) {
      throw FileSystemException('Outside the companion folder', relative);
    }
    return full;
  }
}

/// The user's home folder.
String get homeDir =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.current.path;

/// [path] for showing to people: `~/…` for the home folder on Linux and
/// macOS. Windows users don't know `~`, so they get the full path.
String displayPath(String path) {
  if (Platform.isWindows || !p.isWithin(homeDir, path)) return path;
  return p.join('~', p.relative(path, from: homeDir));
}

/// Everything VoxCordis keeps in plain sight sits in one folder, by default
/// `~/VoxCordis`: one folder per companion, plus `models` for downloads.
class VoxCordisFolder {
  static const name = 'VoxCordis';

  /// The VoxCordis folder inside [parent], or [parent] itself if the user
  /// picked a folder that is already called VoxCordis.
  static String inside(String parent) =>
      p.basename(parent).toLowerCase() == name.toLowerCase()
      ? parent
      : p.join(parent, name);

  static String get defaultRoot => inside(homeDir);

  static String models(String root) => p.join(root, 'models');

  /// The companion's own folder, named after it. Characters no file system
  /// allows are dropped, and a companion called "models" gets its own name.
  static String companion(String root, String companionName) {
    var folder = companionName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    if (folder.isEmpty || folder.startsWith('.')) folder = 'Companion';
    if (folder.toLowerCase() == 'models') folder = '$folder (companion)';
    return p.join(root, folder);
  }
}
