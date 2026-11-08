import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' show Client, ClientException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/database.dart';
import 'data/database_key.dart';
import 'data/locked_chats.dart';
import 'data/desk/desk_tools.dart';
import 'data/memory/memory_repository.dart';
import 'data/memory/memory_tools.dart';
import 'data/message_repository.dart';
import 'data/picture_notes.dart';
import 'data/recall/recall_index.dart';
import 'data/desk/desk_files.dart';
import 'data/desk/pictures.dart';
import 'data/schedule/schedule_repository.dart';
import 'data/schedule/schedule_tools.dart';
import 'data/settings.dart';
import 'data/story_repository.dart';
import 'data/voces/story_log.dart';
import 'data/skills/skill_tools.dart';
import 'features/chat/prompt_history.dart';
import 'services/changelog.dart';
import 'services/import/import_temp.dart';
import 'services/system/older_copy.dart';
import 'services/images/clip_prompt.dart';
import 'services/import/personality_rewrite.dart';
import 'services/images/draw_tools.dart';
import 'services/images/image_engine.dart';
import 'services/llm_client.dart';
import 'services/logs/app_log.dart';
import 'services/recall/embedder.dart';
import 'services/recall/recall.dart';
import 'services/runtime/model_catalog.dart';
import 'services/runtime/llama_server.dart' show serverExitHint;
import 'services/runtime/runtime_controller.dart';
import 'services/secret_store.dart';
import 'services/story/story_keeper.dart';
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
    runtime.installer.note = (m) => log.add(LogKind.errors, m);
    final s = settings.value;
    vocesOpen.value =
        s.vocesMundi && s.openOnStart == OpenOnStart.lastPlace && s.lastInVoces;
    startPicker =
        s.openOnStart == OpenOnStart.picker &&
        (s.otherCompanions.isNotEmpty || s.vocesMundi);
    _keepLoadedForVoces();
    settings.addListener(_keepLoadedForVoces);
    // Remembered, so "Where I left off" can open Voces Mundi again.
    vocesOpen.addListener(() {
      final open = vocesOpen.value;
      _keepLoadedForVoces();
      if (settings.value.lastInVoces != open) {
        settings.update(settings.value.copyWith(lastInVoces: open));
      }
    });
  }

  /// Voces Mundi keeps the model loaded while it is open, when Settings
  /// says so; leaving it starts the usual wait.
  void _keepLoadedForVoces() {
    final s = settings.value;
    final keep = vocesOpen.value && s.vocesMundi && s.vocesKeepLoaded;
    if (runtime.keepLoaded == keep) return;
    runtime.keepLoaded = keep;
    runtime.touch(s);
  }

  /// The companion picker is still to show, once, as the window opens.
  bool startPicker = false;

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
  late RecallIndex recallIndex;
  late StoryRepository story;

  void _use(Database next) {
    db = next;
    memory = MemoryRepository(next);
    messages = MessageRepository(next);
    memoryTools = MemoryTools(memory);
    pictureNotes = PictureNotes(next);
    recallIndex = RecallIndex(next);
    story = StoryRepository(next);
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

  /// Before the app quits (an update, Quit from the tray): the last log
  /// lines are written and the database closed, so no write is cut off
  /// half-way. A cut-off write leaves a journal that has to be rolled back
  /// at the next start.
  Future<void> closeForExit() async {
    await runtime.stopAll();
    await log.flush();
    try {
      await db.close();
    } on Object {
      // Already closed, or busy: the journal covers it.
    }
  }

  /// Adds the chats a start over set aside in [folder] (see
  /// [DatabaseKey.setAside]) back to the companions' chats, with [oldKey]
  /// their key. Returns how many messages came back.
  Future<int> bringBackLocked(Directory folder, String oldKey) async {
    final n = await LockedChats(dbKey).bringBack(
      folder,
      oldKey,
      open: db,
      openPath: companionDbPath(
        runtime.supportDir.path,
        settings.value.companionId,
      ),
    );
    memoryChanged();
    scheduleChanged();
    recall.update().ignore();
    resets.value++;
    return n;
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
    scheduleChanged();
    await old.close();
    runtime.ensureReady(next).ignore();
    rewriteIfAsked().ignore();
    recall.update().ignore();
  }

  /// Removes the current companion: its chats and memories, and with
  /// [deleteFolder] its folder too. Talks to the next companion, or goes
  /// back to setup when it was the only one.
  Future<void> deleteCurrentCompanion({required bool deleteFolder}) async {
    final s = settings.value;
    final folder = s.companionFolder;
    final next = s.withoutCurrent();
    final gonePath = companionDbPath(runtime.supportDir.path, s.companionId);
    if (next.companionFolder != null) {
      await switchCompanion(next);
    } else {
      // Nobody left: a fresh database waits for the next first companion.
      await db.close();
      await deleteDatabaseFiles(gonePath);
      _use(await openCompanionDb(null));
      await settings.update(next);
      memoryChanged();
      scheduleChanged();
    }
    if (next.companionFolder != null) await deleteDatabaseFiles(gonePath);
    if (deleteFolder && folder != null) {
      final keep = [for (final c in next.companions) c.folder];
      if (canDeleteFolder(
        folder,
        keep: keep,
        supportDir: runtime.supportDir.path,
      )) {
        final dir = Directory(folder);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }
  }

  /// Wipes the current companion's chats, memories and reminders. Who they
  /// are (settings, folder, personality) stays.
  Future<void> resetCurrentCompanion() async {
    final path = companionDbPath(
      runtime.supportDir.path,
      settings.value.companionId,
    );
    await db.close();
    await deleteDatabaseFiles(path);
    _use(await openCompanionDb(settings.value.companionId));
    memoryChanged();
    scheduleChanged();
    resets.value++;
  }

  /// A database file with its write-ahead and journal leftovers.
  static Future<void> deleteDatabaseFiles(String path) async {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  /// Whether [folder] may be deleted with its companion: not when it holds
  /// another companion's folder, or the app's own files.
  static bool canDeleteFolder(
    String folder, {
    required List<String> keep,
    required String supportDir,
  }) {
    final dir = p.canonicalize(folder);
    bool overlaps(String other) {
      final o = p.canonicalize(other);
      return o == dir || p.isWithin(dir, o);
    }

    return !keep.any(overlaps) && !overlaps(supportDir);
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

  /// Turns the human's few words into a prompt for a video model with the
  /// chat model ([ClipPrompt]). Null when it gave nothing usable; throws
  /// when the model can't be reached.
  Future<String?> writeClipPrompt(
    String idea, {
    required bool detailed,
    int? seconds,
    String? model,
    int? chars,
    int? limit,
  }) async {
    final s = settings.value;
    final http = Client();
    runtime.hold();
    try {
      final target = await runtime.ensureReady(s);
      final client = LlmClient(
        baseUrl: target.baseUrl,
        model: target.model,
        apiKey: target.apiKey,
        sampling: samplingFor(s),
        stop: stopFor(s),
        maxTokens: 3000,
        stallWait: const Duration(minutes: 2),
        client: http,
      );
      return await ClipPrompt.write(
        client,
        idea,
        detailed: detailed,
        seconds: seconds,
        model: model,
        chars: chars,
        limit: limit,
      );
    } finally {
      http.close();
      runtime.release(settings.value);
    }
  }

  /// One answer from the chat model to [system] and [user], without the
  /// companion's prompt or tools; null when it can't be reached. [what]
  /// names the request in Logs → Thinking, which shows what came back.
  /// [exact] is for answers in a fixed form (tags, lists): the model is
  /// asked with a low temperature, so a roleplay model keeps to the form.
  Future<String?> askModel(
    String system,
    String user, {
    int maxTokens = 1500,
    String what = 'A helper request',
    bool exact = false,
  }) async {
    final s = settings.value;
    final http = Client();
    runtime.hold();
    final sampling = samplingFor(s);
    try {
      for (var drops = 0; ; drops++) {
        final target = await runtime.ensureReady(s);
        final client = LlmClient(
          baseUrl: target.baseUrl,
          model: target.model,
          apiKey: target.apiKey,
          sampling: exact
              ? {
                  ...sampling,
                  'temperature': min(
                    (sampling['temperature'] ?? 0.3).toDouble(),
                    0.3,
                  ),
                }
              : sampling,
          stop: stopFor(s),
          // Room for a model that thinks anyway: Gemma 4 finetunes like
          // Artemis thought past the whole budget and answered nothing.
          maxTokens: maxTokens + 4000,
          // A helper answer needs no thinking; llama-server turns it on
          // for templates that can think unless told not to.
          extra: s.llmMode == LlmMode.builtIn
              ? const {
                  'chat_template_kwargs': {'enable_thinking': false},
                }
              : const {},
          stallWait: const Duration(minutes: 2),
          client: http,
        );
        final reply = StringBuffer();
        var thought = 0;
        try {
          await for (final e in client.chat([
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ])) {
            if (e is TextDelta) reply.write(e.text);
            if (e is ReasoningDelta) thought += e.text.length;
          }
        } on ClientException catch (e) {
          // The connection dropped: the model server crashed or was
          // stopped. Say how it ended, start it again and ask once more.
          final exit = s.llmMode == LlmMode.builtIn
              ? await runtime.exitOf(target.baseUrl)
              : null;
          log.add(
            LogKind.errors,
            '$what: the connection to the model dropped'
            '${exit == null
                ? ''
                : exit.onPurpose
                ? ' (the app restarted it)'
                : ' (it stopped: ${serverExitHint(exit.code, exit.log)})'}'
            '${drops == 0 ? '; trying again' : ''}. ${e.message}'
            '${exit == null ? '' : '\nExit code: ${exit.code}'}'
            '${exit == null || exit.log.isEmpty ? '' : '\nLast lines it printed:\n${exit.log}'}',
          );
          if (drops > 0) rethrow;
          continue;
        }
        final text = reply.toString();
        final shown = text.trim().replaceAll(RegExp(r'\s+'), ' ');
        log.add(
          LogKind.thinking,
          '$what: the model answered '
          '${shown.isEmpty ? 'nothing' : '"${shown.length > 400 ? '${shown.substring(0, 400)}…' : shown}"'}'
          '${thought > 0 ? ' (after $thought characters of thinking)' : ''}.',
        );
        return text;
      }
    } on Object catch (e) {
      log.add(LogKind.errors, '$what failed: $e');
      rethrow;
    } finally {
      http.close();
      runtime.release(settings.value);
    }
  }

  /// The chat model's reply to [system] and [user], piece by piece, for a
  /// Voces Mundi story. [stop] adds lines that end the reply. Cancelling
  /// the subscription stops the model.
  Stream<String> streamModel(
    String system,
    String user, {
    List<String> stop = const [],
    int maxTokens = 1200,
  }) async* {
    final s = settings.value;
    final http = Client();
    runtime.hold();
    try {
      final target = await runtime.ensureReady(s);
      final client = LlmClient(
        baseUrl: target.baseUrl,
        model: target.model,
        apiKey: target.apiKey,
        sampling: samplingFor(s),
        stop: [...stopFor(s), ...stop],
        maxTokens: maxTokens,
        stallWait: const Duration(minutes: 2),
        client: http,
      );
      await for (final e in client.chat([
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ])) {
        if (e is TextDelta) yield e.text;
      }
    } finally {
      http.close();
      runtime.release(settings.value);
    }
  }

  /// Where story [id]'s turns are kept: encrypted like the chats, outside
  /// the library folder.
  String storyDbPath(String id) =>
      p.join(runtime.supportDir.path, 'stories', '$id.db');

  /// Opens story [id]'s turns.
  Future<StoryLog> openStoryLog(String id) async {
    final path = storyDbPath(id);
    await Directory(p.dirname(path)).create(recursive: true);
    return StoryLog.open(path, key: dbKey.value);
  }

  /// Deletes story [id]'s turns.
  Future<void> deleteStoryLog(String id) async {
    for (final end in const ['', '-journal', '-wal', '-shm']) {
      final f = File('${storyDbPath(id)}$end');
      if (await f.exists()) await f.delete();
    }
  }

  /// Set while the human is setting up another companion from the menu.
  final addingCompanion = ValueNotifier(false);

  /// Set while Voces Mundi, the roleplay mode, fills the window instead of
  /// the companion.
  final vocesOpen = ValueNotifier(false);

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

  /// Finds memories and older chat by meaning, with the Recall model, and
  /// embeds new ones in the background. Replaceable, for tests.
  late Recall recall = Recall(
    index: () => recallIndex,
    memories: () => memory,
    messages: () => messages,
    embedder: Embedder(
      target: () async {
        final server = await runtime.ensureRecall(settings.value);
        return (baseUrl: server.baseUrl, apiKey: server.apiKey);
      },
    ),
    available: () => ModelCatalog.recallInstalled(settings.value),
    paused: () => runtime.busy,
    log: log,
  );

  /// Folds messages that aged out of the prompt into the story so far.
  late final storyKeeper = StoryKeeper(
    settings: () => settings.value,
    runtime: runtime,
    messages: () => messages,
    story: () => story,
    log: log,
  );

  /// Draws the companion's pictures with stable-diffusion.cpp.
  late final imageEngine = ImageEngine(
    supportDir: runtime.supportDir,
    runtime: runtime,
    settings: () => settings.value,
  )..log = log;

  /// draw_picture, which queues a picture on [imageEngine].
  late final drawTools = DrawTools(
    settings: () => settings.value,
    engine: imageEngine,
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
    log: log,
  );

  /// The browser without a window that the companion browses with.
  late final browser = HeadlessBrowser(runtime.supportDir)..log = log;

  /// Settings → Logs: what the browser, the web tools, the brain and
  /// drawing did. Kept in the current companion's database, so encrypted
  /// with it; API keys are blanked out.
  late final log = AppLog(
    db: () => db,
    enabled: (kind) =>
        settings.value.keepLogs && !settings.value.logsOff.contains(kind.name),
    secrets: () => [
      settings.value.llmApiKey,
      settings.value.searchApiKey,
      if (dbKey.unlocked) dbKey.value,
    ],
  );

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

  /// Counts resets of the current companion; the window rebuilds on each,
  /// so no old chat stays on screen.
  final resets = ValueNotifier(0);
  void backgroundChanged() => backgroundRevision.value++;

  /// Settings and the database live in the OS app-support directory, e.g.
  /// `~/.local/share/<app id>/` on Linux, `%APPDATA%\Nucume\VoxCordis\` on
  /// Windows. Downloaded models live in the VoxCordis folder instead.
  ///
  /// Null when an older VoxCordis still running there has been asked to
  /// show its window instead; this copy should quit then, as a second
  /// launch always has.
  static Future<Directory?> supportDir() async {
    final Directory dir = await getApplicationSupportDirectory();
    if (!await _adoptOldFolders(dir)) return null;
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

  /// Older builds kept their data elsewhere; bring it over once, if this
  /// folder has no settings yet:
  /// - Windows named it after the company and product in the exe, and early
  ///   builds said "com.nucume" and "companion".
  /// - Linux and macOS name it after the app id, which was
  ///   `com.nucume.companion` until the program became voxcordisai.
  /// False while an older copy still runs on that data (Linux; the Windows
  /// runner looks for one itself, and macOS has no such check).
  static Future<bool> _adoptOldFolders(Directory dir) => adoptOldFolder(
    dir,
    oldFolderFor(dir, windows: Platform.isWindows),
    removeEmptyParent: Platform.isWindows,
    olderCopyRunning: Platform.isLinux ? OlderCopy.showIfRunning : null,
  );

  /// Where older builds kept what now belongs in [dir].
  @visibleForTesting
  static Directory oldFolderFor(Directory dir, {required bool windows}) =>
      windows
      ? Directory(p.join(dir.parent.parent.path, 'com.nucume', 'companion'))
      : Directory(p.join(dir.parent.path, 'com.nucume.companion'));

  /// Moves what is in [old] into [dir] unless [dir] already has settings,
  /// then points the paths in settings.json that named [old] at [dir].
  /// settings.json goes last. Whatever stayed behind (in use, say) is
  /// named in [pendingFile] and tried again on the next start, even though
  /// settings.json is there by then.
  ///
  /// Returns false, having moved nothing, when [olderCopyRunning] says an
  /// older VoxCordis is still running on [old]. [rename] is for tests.
  @visibleForTesting
  static Future<bool> adoptOldFolder(
    Directory dir,
    Directory old, {
    bool removeEmptyParent = false,
    Future<bool> Function()? olderCopyRunning,
    Future<void> Function(FileSystemEntity entry, String to) rename =
        _renameEntry,
  }) async {
    if (p.equals(old.path, dir.path)) return true;
    final pending = File(p.join(dir.path, pendingFile));
    if (!await old.exists()) {
      await _deleteQuietly(pending.path);
      return true;
    }
    // Only what an earlier start left behind, if it did.
    List<String>? only;
    if (await pending.exists()) {
      try {
        only = (await pending.readAsLines())
            .where((n) => n.isNotEmpty)
            .toList();
      } on FileSystemException {
        only = const [];
      }
    } else if (await File(p.join(dir.path, 'settings.json')).exists()) {
      return true;
    }
    // It has the database and settings open: moving them would lose what
    // it saves from then on.
    if (olderCopyRunning != null && await olderCopyRunning()) return false;
    final relinked = only == null && await _relinkOldFolder(dir, old);
    var fixPaths = relinked;
    // Left for want of space: too big to copy again on every start, and
    // their paths in settings keep pointing at them.
    final full = <String>[];
    if (!relinked) {
      await dir.create(recursive: true);
      final left = <String>[];
      FileSystemEntity? oldSettings;
      // Links are moved as links, not copied with all they point at.
      await for (final e in old.list(followLinks: false)) {
        final name = p.basename(e.path);
        // settings.json is never filtered out: a start cut short just
        // before it moved still has it to move.
        if (name == 'settings.json') {
          oldSettings = e;
          continue;
        }
        if (only != null && !only.contains(name)) continue;
        final target = p.join(dir.path, name);
        if (await _exists(target)) continue;
        switch (await _moveEntry(e, target, rename)) {
          case _Moved.yes:
            break;
          case _Moved.no:
            left.add(name);
          case _Moved.noSpace:
            full.add(name);
        }
      }
      // Named before settings.json moves, so a start cut short after it
      // still finds what is left.
      if (left.isNotEmpty) await _writePending(pending, left);
      final settingsTarget = p.join(dir.path, 'settings.json');
      if (oldSettings != null && !await _exists(settingsTarget)) {
        if (await _moveEntry(oldSettings, settingsTarget, rename) ==
                _Moved.yes ||
            await _copySettings(oldSettings, settingsTarget)) {
          fixPaths = true;
        } else {
          left.add('settings.json');
        }
      }
      if (left.isEmpty) {
        await _deleteQuietly(pending.path);
      } else {
        await _writePending(pending, left);
      }
      if (left.isNotEmpty) {
        debugPrint('Left in ${old.path} until next time: ${left.join(', ')}');
      }
      if (full.isNotEmpty) {
        debugPrint('Left in ${old.path}, no space: ${full.join(', ')}');
      }
    }
    final settings = File(p.join(dir.path, 'settings.json'));
    try {
      if (fixPaths && await settings.exists()) {
        // As written in JSON too, where Windows' backslashes are doubled.
        String json(String path) {
          final quoted = jsonEncode(path);
          return quoted.substring(1, quoted.length - 1);
        }

        // Not followed by a separator and one of the names in [full].
        final keep = [
          for (final n in full)
            r'(?![\\/]+' + RegExp.escape(n) + r'(?![^\\/"]))',
        ].join();
        String swap(String text, String from, String to) =>
            text.replaceAll(RegExp(RegExp.escape(from) + keep), to);

        final text = await settings.readAsString();
        final fixed = swap(
          swap(text, json(old.path), json(dir.path)),
          old.path,
          dir.path,
        );
        if (fixed != text) await settings.writeAsString(fixed);
      }
    } on FileSystemException {
      // Leave the paths as they are.
    }
    for (final d in [old, if (removeEmptyParent) old.parent]) {
      try {
        await d.delete(); // only if it is empty now
      } on FileSystemException {
        break;
      }
    }
    return true;
  }

  /// Names what [adoptOldFolder] left in the old folder, one per line.
  @visibleForTesting
  static const pendingFile = '.adopt-pending';

  static Future<void> _writePending(File pending, List<String> names) async {
    try {
      await pending.writeAsString('${names.join('\n')}\n');
    } on FileSystemException {
      // Not tried again then.
    }
  }

  static Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  static Future<void> _renameEntry(FileSystemEntity e, String to) =>
      e.rename(to);

  /// The old folder as a link to somewhere else (another drive, often):
  /// point the new name there too, rather than copying it all over. False
  /// if it is no link, or the new folder already has something in it.
  static Future<bool> _relinkOldFolder(Directory dir, Directory old) async {
    try {
      if (!await FileSystemEntity.isLink(old.path)) return false;
      if (await dir.exists()) {
        if (!await dir.list().isEmpty) return false;
        await dir.delete();
      }
      final link = Link(old.path);
      final to = p.normalize(p.join(old.parent.path, await link.target()));
      await Link(dir.path).create(to);
      await link.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Moves [e] to [target]. Onto another drive, where it can't simply be
  /// renamed, it is copied and then deleted.
  /// A settings.json that won't move (held open by a virus scanner, say)
  /// can usually still be read: copy it, so the user's settings arrive.
  static Future<bool> _copySettings(FileSystemEntity from, String to) async {
    if (from is! File) return false;
    try {
      await from.copy(to);
    } on FileSystemException {
      await _deleteQuietly(to);
      return false;
    }
    await _deleteQuietly(from.path);
    return true;
  }

  static Future<_Moved> _moveEntry(
    FileSystemEntity e,
    String target,
    Future<void> Function(FileSystemEntity entry, String to) rename,
  ) async {
    try {
      await rename(e, target);
      return _Moved.yes;
    } on FileSystemException catch (error) {
      if (_noSpace(error)) return _Moved.noSpace;
      // In use or locked: leave it. EXDEV is 18; Windows says 17.
      final otherDrive = Platform.isWindows ? 17 : 18;
      if (error.osError?.errorCode != otherDrive) return _Moved.no;
    }
    // Copied beside the target first, so a cut-off copy is never taken for
    // the real thing.
    final copy = '$target.moving';
    try {
      await (await _copyEntry(e, copy)).rename(target);
    } on FileSystemException catch (error) {
      await _deleteQuietly(copy);
      return _noSpace(error) ? _Moved.noSpace : _Moved.no;
    }
    // Moved all the same if some of the old one can't go.
    await _deleteQuietly(e.path);
    return _Moved.yes;
  }

  /// ENOSPC is 28; Windows says 112, or 39.
  static bool _noSpace(FileSystemException e) =>
      (Platform.isWindows ? const [39, 112] : const [28]).contains(
        e.osError?.errorCode,
      );

  /// Copies [e] to [to], links as links, and returns the copy.
  static Future<FileSystemEntity> _copyEntry(
    FileSystemEntity e,
    String to,
  ) async {
    if (e is Link) return Link(to).create(await e.target());
    if (e is File) return e.copy(to);
    final dir = await Directory(to).create();
    await for (final child in (e as Directory).list(followLinks: false)) {
      await _copyEntry(child, p.join(to, p.basename(child.path)));
    }
    return dir;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      switch (await FileSystemEntity.type(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.notFound:
          break;
        default:
          await File(path).delete();
      }
    } on FileSystemException {
      // Left where it is.
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

/// How an entry fared in [AppServices.adoptOldFolder].
enum _Moved { yes, no, noSpace }
