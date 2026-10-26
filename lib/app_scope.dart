import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' show Client;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/database.dart';
import 'data/database_key.dart';
import 'data/desk/desk_tools.dart';
import 'data/memory/memory_repository.dart';
import 'data/memory/memory_tools.dart';
import 'data/message_repository.dart';
import 'data/picture_notes.dart';
import 'data/desk/desk_files.dart';
import 'data/desk/pictures.dart';
import 'data/schedule/schedule_repository.dart';
import 'data/schedule/schedule_tools.dart';
import 'data/settings.dart';
import 'data/skills/skill_tools.dart';
import 'features/chat/prompt_history.dart';
import 'services/changelog.dart';
import 'services/import/import_temp.dart';
import 'services/import/personality_rewrite.dart';
import 'services/llm_client.dart';
import 'services/runtime/model_catalog.dart';
import 'services/runtime/runtime_controller.dart';
import 'services/secret_store.dart';
import 'services/system/background.dart';
import 'services/system/desktop_notifier.dart';
import 'services/system/system_tools.dart';
import 'services/updater.dart';
import 'services/web/headless_browser.dart';
import 'services/web/web_tools.dart';

/// The app's long-lived objects, created once at startup.
class AppServices {
  AppServices({
    required this.settings,
    required Database db,
    required this.runtime,
    required this.dbKey,
  }) {
    _use(db);
  }

  final SettingsStore settings;
  final RuntimeController runtime;
  final updates = Updater();

  /// Encrypts every companion database; Settings → Privacy shows it.
  final DatabaseKey dbKey;

  /// What changed since the version that ran before, found at startup;
  /// the main window shows it once and clears it.
  ({String? from, List<ChangelogEntry> notes})? whatsNew;

  /// The current companion's chats and memories. Each companion has its own
  /// database; these change when the human switches companion.
  late Database db;
  late MemoryRepository memory;
  late MessageRepository messages;
  late MemoryTools memoryTools;
  late PictureNotes pictureNotes;
  late ScheduleRepository schedules;
  late ScheduleTools scheduleTools;

  void _use(Database next) {
    db = next;
    memory = MemoryRepository(next);
    messages = MessageRepository(next);
    memoryTools = MemoryTools(memory);
    pictureNotes = PictureNotes(next);
    schedules = ScheduleRepository(next);
    scheduleTools = ScheduleTools(schedules, onChanged: scheduleChanged);
    // What the companion forgot over a month ago goes for good.
    memory.purgeForgotten().ignore();
  }

  /// Opens the database of the companion with [id] (see
  /// [AppSettings.companionId]), creating it the first time.
  Future<Database> openCompanionDb(String? id) async {
    final path = companionDbPath(runtime.supportDir.path, id);
    await Directory(p.dirname(path)).create(recursive: true);
    return openAppDatabase(path, key: dbKey.value);
  }

  /// Re-encrypts every companion database with [next] (a new random key,
  /// or the human's own password).
  Future<void> changeDatabaseKey(String next) => dbKey.change(
    next,
    open: db,
    openPath: companionDbPath(
      runtime.supportDir.path,
      settings.value.companionId,
    ),
  );

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
    scheduleChanged();
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
    var held = false;
    try {
      final file = DeskFiles.fileIn(folder, DeskFiles.personality);
      if (!await file.exists() ||
          !PersonalityRewrite.pending(await file.readAsString())) {
        return;
      }
      rewriting.value = (label: 'Rewriting personality…', problem: null);
      runtime.hold();
      held = true;
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
      if (held) runtime.release(settings.value);
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
        colorway: look.colorway,
      ),
    ),
    onBackgroundPicture: () async => backgroundChanged(),
    onThemeSet: (theme) =>
        settings.update(settings.value.copyWith(themeChoice: theme)),
    onAvatarSet: (avatar) async {
      await FileImage(avatar).evict();
      await settings.update(settings.value.copyWith(portraitPath: avatar.path));
    },
  );

  /// use_skill, for the companion's skills folder.
  late final skillTools = SkillTools(settings: () => settings.value);

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

  /// Search, reading pages and the companion's own browser, while
  /// Settings → Internet allows them. The window supplies the approval
  /// dialog ([WebTools.ask]).
  late final webTools = WebTools(
    settings: () => settings.value,
    browser: browser,
    searchKey: () async => settings.value.searchApiKey,
  );

  /// The browser without a window that the companion browses with.
  late final browser = HeadlessBrowser(runtime.supportDir);

  /// Desktop notifications for reminders and finished tasks.
  DesktopNotifier notifier = const DesktopNotifier();

  /// Keeps running with the window closed; set at startup by main.
  Background? background;

  /// Bumped whenever reminders or tasks change, so the list reloads.
  final scheduleRevision = ValueNotifier(0);
  void scheduleChanged() => scheduleRevision.value++;

  /// Bumped whenever memories change, so open views can reload.
  final memoryRevision = ValueNotifier(0);
  void memoryChanged() => memoryRevision.value++;

  /// Bumped whenever the companion's background picture is set or removed,
  /// so the window repaints it.
  final backgroundRevision = ValueNotifier(0);
  void backgroundChanged() => backgroundRevision.value++;

  /// Settings and the database live in the OS app-support directory, e.g.
  /// `~/.local/share/<app id>/` on Linux, `%APPDATA%\Nucume\VoxCordis\` on
  /// Windows. Downloaded models live in the VoxCordis folder instead.
  static Future<Directory> supportDir() async {
    final Directory dir = await getApplicationSupportDirectory();
    if (Platform.isWindows) await _adoptOldWindowsFolder(dir);
    await dir.create(recursive: true);
    // Chats, memories, settings and logs: for this user's eyes only, as are
    // the companions' folders (personality, lessons, privacy rules).
    await restrictToOwner(dir.path, directory: true);
    return dir;
  }

  /// Everything the window needs, once [key] is unlocked
  /// ([DatabaseKey.unlock]).
  static Future<AppServices> open(Directory dir, DatabaseKey key) async {
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
        key: key.value,
      ),
      runtime: RuntimeController(dir),
      dbKey: key,
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
