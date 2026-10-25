import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' show Client;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/database.dart';
import 'data/desk/desk_tools.dart';
import 'data/memory/memory_repository.dart';
import 'data/memory/memory_tools.dart';
import 'data/message_repository.dart';
import 'data/desk/desk_files.dart';
import 'data/desk/pictures.dart';
import 'data/settings.dart';
import 'features/chat/prompt_history.dart';
import 'services/import/import_temp.dart';
import 'services/import/personality_rewrite.dart';
import 'services/llm_client.dart';
import 'services/runtime/model_catalog.dart';
import 'services/runtime/runtime_controller.dart';
import 'services/secret_store.dart';
import 'services/system/system_tools.dart';
import 'services/updater.dart';

/// The app's long-lived objects, created once at startup.
class AppServices {
  AppServices({
    required this.settings,
    required Database db,
    required this.runtime,
  }) {
    _use(db);
  }

  final SettingsStore settings;
  final RuntimeController runtime;
  final updates = Updater();

  /// The current companion's chats and memories. Each companion has its own
  /// database; these change when the human switches companion.
  late Database db;
  late MemoryRepository memory;
  late MessageRepository messages;
  late MemoryTools memoryTools;

  void _use(Database next) {
    db = next;
    memory = MemoryRepository(next);
    messages = MessageRepository(next);
    memoryTools = MemoryTools(memory);
    // What the companion forgot over a month ago goes for good.
    memory.purgeForgotten().ignore();
  }

  /// Opens the database of the companion with [id] (see
  /// [AppSettings.companionId]), creating it the first time.
  Future<Database> openCompanionDb(String? id) async {
    final path = companionDbPath(runtime.supportDir.path, id);
    await Directory(p.dirname(path)).create(recursive: true);
    return openAppDatabase(path);
  }

  /// `companion.db` for the first companion, `companions/<id>.db` for every
  /// one added after it.
  static String companionDbPath(String supportDir, String? id) => id == null
      ? p.join(supportDir, 'companion.db')
      : p.join(supportDir, 'companions', '$id.db');

  /// Talks to [next]'s companion from now on. [nextDb] is its database when
  /// already open (setup writes an import into it first). The window
  /// rebuilds around the new companion, so nothing may still be writing to
  /// the old database.
  Future<void> switchCompanion(AppSettings next, {Database? nextDb}) async {
    final old = db;
    final opened = nextDb ?? await openCompanionDb(next.companionId);
    if (identical(opened, old)) return;
    _use(opened);
    await settings.update(next);
    memoryChanged();
    await old.close();
    runtime.ensureReady(next).ignore();
    rewriteIfAsked().ignore();
  }

  /// What the rewrite of an imported character is doing: its progress
  /// while it runs, why it didn't work after a failure, else null.
  final rewriting = ValueNotifier<({String label, String? problem})?>(null);

  /// Rewrites the current companion's personality.md when its human asked
  /// for that at import ([PersonalityRewrite]). Waits for the model.
  Future<void> rewriteIfAsked() async {
    if (_rewriteRunning) return;
    final s = settings.value;
    final folder = s.companionFolder;
    if (!s.isSetUp || folder == null) return;
    _rewriteRunning = true;
    final http = Client();
    ({String label, String? problem})? after;
    try {
      final file = DeskFiles.fileIn(folder, DeskFiles.personality);
      if (!await file.exists() ||
          !PersonalityRewrite.pending(await file.readAsString())) {
        return;
      }
      rewriting.value = (label: 'Rewriting personality…', problem: null);
      final target = await runtime.ensureReady(s);
      final maxChars = DeskFiles.personalityMaxChars(s.contextSize);
      final client = LlmClient(
        baseUrl: target.baseUrl,
        model: target.model,
        apiKey: target.apiKey,
        sampling: samplingFor(s),
        stop: stopFor(s),
        // Room for a thinking model to think first.
        maxTokens: 6000,
        stallWait: const Duration(minutes: 3),
        client: http,
      );
      // The human may have switched companion meanwhile.
      if (settings.value.companionFolder != folder) return;
      final r = await PersonalityRewrite.run(
        file,
        client,
        name: s.companionName,
        pronouns: s.pronouns,
        maxChars: maxChars,
        progress: (done, of) => rewriting.value = (
          label: 'Rewriting personality ${done + 1 > of ? of : done + 1}/$of…',
          problem: null,
        ),
      );
      if (r.rewritten == 0 && r.problem != null) {
        after = (label: 'Rewrite didn\'t work', problem: r.problem);
      }
    } on Object catch (e) {
      debugPrint('Personality rewrite failed: $e');
      after = (label: 'Rewrite didn\'t work', problem: '$e');
    } finally {
      http.close();
      _rewriteRunning = false;
      rewriting.value = after;
    }
  }

  bool _rewriteRunning = false;

  /// Set while the human is setting up another companion from the menu.
  final addingCompanion = ValueNotifier(false);

  /// File tools for the companion folder. Saving personality.md updates the
  /// name, traits and pronouns shown on the companion card, and set_avatar
  /// its portrait.
  late final deskTools = DeskTools(
    settings: () => settings.value,
    onPersonalitySaved: (who) => settings.update(
      settings.value.copyWith(
        traits: who.traits,
        companionName: who.name,
        pronouns: who.pronouns,
      ),
    ),
    // The file may keep its name with new content: drop the cached image,
    // and save the path so the card redraws.
    onBackgroundSet: (look) => settings.update(
      settings.value.copyWith(
        backgroundColors: look.colors,
        backgroundLayout: look.layout,
        accentColor: look.accent,
      ),
    ),
    onThemeSet: (theme) =>
        settings.update(settings.value.copyWith(themeChoice: theme)),
    onAvatarSet: (avatar) async {
      await FileImage(avatar).evict();
      await settings.update(settings.value.copyWith(portraitPath: avatar.path));
    },
  );

  /// Commands and opening things on this computer, while system access is
  /// on. The window supplies the approval dialog ([SystemTools.ask]).
  late final systemTools = SystemTools(
    settings: () => settings.value,
    logFile: systemLog,
    allowAlways: (key) => settings.update(
      settings.value.copyWith(
        allowedSystemActions: [...settings.value.allowedSystemActions, key],
      ),
    ),
  );

  /// Every command run and thing opened, with the human's answer.
  File get systemLog =>
      File(p.join(runtime.supportDir.path, 'system-access.log'));

  /// Bumped whenever memories change, so open views can reload.
  final memoryRevision = ValueNotifier(0);
  void memoryChanged() => memoryRevision.value++;

  /// Settings and the database live in the OS app-support directory, e.g.
  /// `~/.local/share/<app id>/` on Linux, `%APPDATA%\Nucume\VoxCordis\` on
  /// Windows. Downloaded models live in the VoxCordis folder instead.
  static Future<AppServices> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    if (Platform.isWindows) await _adoptOldWindowsFolder(dir);
    await dir.create(recursive: true);
    // Chats, memories, settings and logs: for this user's eyes only, as are
    // the companions' folders (personality, lessons, privacy rules).
    await restrictToOwner(dir.path, directory: true);
    final settings = await SettingsStore.load(dir);
    for (final c in settings.value.companions) {
      if (Directory(c.folder).existsSync()) {
        await restrictToOwner(c.folder, directory: true);
      }
    }
    await _settleImportedPortrait(settings);
    await _moveOldModels(dir, settings);
    return AppServices(
      settings: settings,
      db: await openAppDatabase(
        companionDbPath(dir.path, settings.value.companionId),
      ),
      runtime: RuntimeController(dir),
    );
  }

  /// Early test builds left an imported portrait's path pointing at its
  /// temporary copy; point at the avatar in the companion's folder. Then
  /// clear the temporary pictures of imports that never finished, keeping
  /// any another companion still points at.
  static Future<void> _settleImportedPortrait(SettingsStore store) async {
    final s = store.value;
    final folder = s.companionFolder;
    if (folder != null && ImportTemp.holds(s.portraitPath)) {
      final avatar = Pictures.avatarIn(folder);
      if (avatar != null) {
        await store.update(s.copyWith(portraitPath: avatar.path));
      }
    }
    ImportTemp.clearAll(
      keep: [for (final c in store.value.companions) c.portraitPath],
    ).ignore();
  }

  /// Windows names this folder after the company and product in the exe.
  /// Early builds said "com.nucume" and "companion"; bring that folder's
  /// settings, chats and downloads over once.
  static Future<void> _adoptOldWindowsFolder(Directory dir) async {
    final old = Directory(
      p.join(dir.parent.parent.path, 'com.nucume', 'companion'),
    );
    if (!await old.exists()) return;
    if (await File(p.join(dir.path, 'settings.json')).exists()) return;
    await dir.create(recursive: true);
    await for (final e in old.list()) {
      final target = p.join(dir.path, p.basename(e.path));
      if (await FileSystemEntity.type(target) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      try {
        await e.rename(target);
      } on FileSystemException {
        // In use or locked: leave it.
      }
    }
    for (final d in [old, old.parent]) {
      try {
        await d.delete(); // only if it is empty now
      } on FileSystemException {
        break;
      }
    }
  }

  /// Models used to be downloaded into the hidden app folder. Move them to
  /// the VoxCordis folder where people can find them. If they can't simply
  /// be renamed there (another drive, say), keep using the old folder; it
  /// shows in Settings and can be moved from there.
  static Future<void> _moveOldModels(Directory dir, SettingsStore store) async {
    final s = store.value;
    final old = Directory(p.join(dir.path, 'models'));
    if (s.modelsFolder != null || !await old.exists()) return;
    final to = ModelCatalog.dirFor(s);
    try {
      if (await to.exists()) throw const FileSystemException('exists');
      await to.parent.create(recursive: true);
      await old.rename(to.path);
      await store.update(
        s.copyWith(
          modelsFolder: to.path,
          modelPath: ModelCatalog.movedPath(s.modelPath, old, to),
        ),
      );
    } on FileSystemException {
      await store.update(s.copyWith(modelsFolder: old.path));
    }
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
