import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/secret_store.dart';

enum LlmMode { builtIn, external }

/// Light or dark look. System follows the OS, and is dark when the OS
/// doesn't say.
enum ThemeChoice { system, light, dark }

/// The range of the interface size slider in Settings.
const minInterfaceScale = 0.8;
const maxInterfaceScale = 1.5;

/// Where the light that says whether the brain is ready sits: on the
/// portrait's corner, next to the companion's name, or as the labelled
/// chip in the chat's top bar.
enum StatusLight { portrait, name, header }

/// How Settings shows its pages: a glass pill row across the top, or a
/// glass rail down the left.
enum SettingsTabs { top, side }

/// Where web_search looks: DuckDuckGo needs no account, Brave and Tavily
/// want a key, SearXNG is an instance the human names.
enum SearchProvider { duckDuckGo, brave, tavily, searxng }

/// What draws the companion's pictures: nothing yet, VoxCordis itself
/// (stable-diffusion.cpp on this computer), or an InvokeAI the human runs.
enum ImageEngineChoice { off, builtIn, invoke }

/// What happens when the human logs in to the computer.
enum StartMode { off, onScreen, minimized }

/// What the window opens to: where the human left off (the companion, or
/// Voces Mundi when they closed the app there), always the companion, or
/// the companion picker.
enum OpenOnStart { lastPlace, companion, picker }

/// What one picture model was last drawn with in the draw panel. A null
/// number means "the model's own default".
@immutable
class DrawChoices {
  const DrawChoices({
    this.width,
    this.height,
    this.steps,
    this.cfg,
    this.seed,
    this.negative = '',
    this.loras = const {},
    this.sampler,
    this.scheduler,
  });

  final int? width;
  final int? height;
  final int? steps;
  final double? cfg;
  final int? seed;
  final String negative;

  /// sd-cli's sampling method and scheduler, or null for the model's own.
  final String? sampler;
  final String? scheduler;

  /// The LoRAs picked for this model, by name, with their strength.
  final Map<String, double> loras;

  bool get isEmpty =>
      width == null &&
      height == null &&
      steps == null &&
      cfg == null &&
      seed == null &&
      negative.isEmpty &&
      loras.isEmpty &&
      sampler == null &&
      scheduler == null;

  Map<String, Object?> toJson() => {
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (steps != null) 'steps': steps,
    if (cfg != null) 'cfg': cfg,
    if (seed != null) 'seed': seed,
    if (negative.isNotEmpty) 'negative': negative,
    if (loras.isNotEmpty) 'loras': loras,
    if (sampler != null) 'sampler': sampler,
    if (scheduler != null) 'scheduler': scheduler,
  };

  factory DrawChoices.fromJson(Map<String, Object?> json) {
    final loras = json['loras'];
    return DrawChoices(
      width: json['width'] as int?,
      height: json['height'] as int?,
      steps: json['steps'] as int?,
      cfg: (json['cfg'] as num?)?.toDouble(),
      seed: json['seed'] as int?,
      negative: json['negative'] as String? ?? '',
      sampler: json['sampler'] as String?,
      scheduler: json['scheduler'] as String?,
      loras: {
        if (loras is Map)
          for (final e in loras.entries)
            if (e.key is String && e.value is num)
              e.key as String: (e.value as num).toDouble().clamp(-1, 2),
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DrawChoices &&
      other.width == width &&
      other.height == height &&
      other.steps == steps &&
      other.cfg == cfg &&
      other.seed == seed &&
      other.negative == negative &&
      other.sampler == sampler &&
      other.scheduler == scheduler &&
      mapEquals(other.loras, loras);

  @override
  int get hashCode => Object.hash(
    width,
    height,
    steps,
    cfg,
    seed,
    negative,
    sampler,
    scheduler,
    Object.hashAllUnordered(
      loras.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// The draw panel as it was left: the Advanced switch, the picture model,
/// the shape, and each model's own size, steps, guidance, seed, negative
/// prompt and LoRAs, so switching models brings back what that model was last given.
@immutable
class DrawPanelPrefs {
  const DrawPanelPrefs({
    this.advanced = false,
    this.model,
    this.shape = 'square',
    this.perModel = const {},
    this.lorasOpen = false,
    this.width,
    this.height,
    this.ratio,
    this.presets = const [],
  });

  final bool advanced;

  /// Prompts saved as favourites, to load into the Draw panel any time.
  final List<DrawPreset> presets;

  /// The size typed in the advanced options, kept whichever model is
  /// picked, and the width:height ratio ("9:16") that ties them; null for
  /// the shape's own size and no ratio.
  final int? width;
  final int? height;
  final String? ratio;

  /// Whether the LoRAs section shows every LoRA or only the picked ones.
  final bool lorasOpen;
  final String? model;
  final String shape;
  final Map<String, DrawChoices> perModel;

  DrawPanelPrefs copyWith({
    bool? advanced,
    String? model,
    String? shape,
    Map<String, DrawChoices>? perModel,
    bool? lorasOpen,
    List<DrawPreset>? presets,
  }) => DrawPanelPrefs(
    advanced: advanced ?? this.advanced,
    lorasOpen: lorasOpen ?? this.lorasOpen,
    model: model ?? this.model,
    shape: shape ?? this.shape,
    perModel: perModel ?? this.perModel,
    width: width,
    height: height,
    ratio: ratio,
    presets: presets ?? this.presets,
  );

  /// These prefs with the typed size and ratio set to these (null clears).
  DrawPanelPrefs withSize({int? width, int? height, String? ratio}) =>
      DrawPanelPrefs(
        advanced: advanced,
        lorasOpen: lorasOpen,
        model: model,
        shape: shape,
        perModel: perModel,
        width: width,
        height: height,
        ratio: ratio,
        presets: presets,
      );

  /// These prefs with [choices] kept for [model]; empty choices are dropped.
  DrawPanelPrefs withChoices(String model, DrawChoices choices) {
    final next = {...perModel};
    if (choices.isEmpty) {
      next.remove(model);
    } else {
      next[model] = choices;
    }
    return copyWith(perModel: next);
  }

  Map<String, Object?> toJson() => {
    'advanced': advanced,
    'model': model,
    'shape': shape,
    'lorasOpen': lorasOpen,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (ratio != null) 'ratio': ratio,
    'perModel': {for (final e in perModel.entries) e.key: e.value.toJson()},
    if (presets.isNotEmpty) 'presets': [for (final p in presets) p.toJson()],
  };

  factory DrawPanelPrefs.fromJson(Object? json) {
    if (json is! Map) return const DrawPanelPrefs();
    final per = json['perModel'];
    return DrawPanelPrefs(
      advanced: json['advanced'] as bool? ?? false,
      lorasOpen: json['lorasOpen'] as bool? ?? false,
      model: json['model'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      ratio: json['ratio'] as String?,
      shape: switch (json['shape']) {
        'portrait' => 'portrait',
        'landscape' => 'landscape',
        _ => 'square',
      },
      perModel: {
        if (per is Map)
          for (final e in per.entries)
            if (e.key is String && e.value is Map)
              e.key as String: DrawChoices.fromJson(
                Map<String, Object?>.from(e.value as Map),
              ),
      },
      presets: [
        if (json['presets'] is List)
          for (final p in json['presets'] as List)
            if (DrawPreset.fromJson(p) case final preset?) preset,
      ],
    );
  }
}

/// A favourite prompt: a name, the prompt and what to leave out.
class DrawPreset {
  const DrawPreset({
    required this.name,
    required this.prompt,
    this.negative = '',
  });

  final String name;
  final String prompt;
  final String negative;

  Map<String, Object?> toJson() => {
    'name': name,
    'prompt': prompt,
    if (negative.isNotEmpty) 'negative': negative,
  };

  static DrawPreset? fromJson(Object? json) {
    if (json is! Map || json['prompt'] is! String) return null;
    final prompt = json['prompt']! as String;
    return DrawPreset(
      name: json['name'] is String && (json['name']! as String).isNotEmpty
          ? json['name']! as String
          : prompt,
      prompt: prompt,
      negative: json['negative'] is String ? json['negative']! as String : '',
    );
  }
}

/// Everything the minimal v1 Settings page edits.
@immutable
class AppSettings {
  const AppSettings({
    this.companionName = 'Companion',
    this.pronouns = 'she/her',
    this.traits = const ['curious', 'warm'],
    this.userName = '',
    this.userPronouns = '',
    this.portraitPath,
    this.companionFolder,
    this.llmMode = LlmMode.builtIn,
    this.modelPath,
    this.modelsFolder,
    this.contextSize = 8192,
    this.useGpu = true,
    this.freeGpuWhenIdle = false,
    this.idleMinutes = 1,
    this.vocesKeepLoaded = true,
    this.chatFormat,
    this.mmprojPath,
    this.temperature,
    this.llmEndpoint = 'http://localhost:11434/v1',
    this.llmModel = '',
    this.llmApiKey = '',
    this.invokeUrl = 'http://localhost:9090',
    this.accentColor = 0xFFB18CFF,
    this.backgroundColors = const [],
    this.backgroundLayout,
    this.colorway,
    this.themeChoice = ThemeChoice.system,
    this.statusLight = StatusLight.portrait,
    this.settingsTabs = SettingsTabs.top,
    this.backgroundDim = 0.6,
    this.interfaceScale = 1.0,
    this.videoVolume = 100,
    this.playVideoPortraits = true,
    this.showNsfwAvatar = false,
    this.systemAccess = false,
    this.allowedSystemActions = const [],
    this.allowEverything = false,
    this.companionId,
    this.otherCompanions = const [],
    this.toldAboutMoreCompanions = false,
    this.picturesToServerOk = false,
    this.internetAccess = false,
    this.companionBrowser = false,
    this.searchProvider = SearchProvider.duckDuckGo,
    this.searxngUrl = '',
    this.searchApiKey = '',
    this.blockedSites = const [],
    this.keepRunning = false,
    this.keepLogs = true,
    this.vocesMundi = false,
    this.vocesMature = false,
    this.vocesBackdrop = true,
    this.logsOff = const [],
    this.startMode = StartMode.off,
    this.openOnStart = OpenOnStart.lastPlace,
    this.lastInVoces = false,
    this.automationRunsPerDay = 24,
    this.imageEngine = ImageEngineChoice.off,
    this.imageModel,
    this.freeGpuForDrawing = true,
    this.draw = const DrawPanelPrefs(),
    this.pokeAfterHours = 3,
    this.pokeQuietFrom = 23,
    this.pokeQuietUntil = 8,
    this.pokeRepeat = false,
  });

  final String companionName;
  final String pronouns;
  final List<String> traits;

  /// What the companion calls its human, and their pronouns; empty until
  /// they say.
  final String userName;
  final String userPronouns;
  final String? portraitPath;

  /// Root of the companion's files, e.g. `~/Aria/`. Null until setup.
  final String? companionFolder;

  /// Built-in runtime (default) or an external server the user runs.
  final LlmMode llmMode;

  /// The .gguf the built-in runtime loads.
  final String? modelPath;

  /// Where downloads go; null means `~/VoxCordis/models`.
  final String? modelsFolder;
  final int contextSize;
  final bool useGpu;

  /// Unloads the model (and Eyes) after a minute without typing, so games
  /// get the graphics card back; typing loads it again.
  final bool freeGpuWhenIdle;

  /// Minutes without typing before [freeGpuWhenIdle] unloads the models.
  final int idleMinutes;

  /// While Voces Mundi is open, [freeGpuWhenIdle] waits: reading and
  /// writing a turn there takes longer than a chat message.
  final bool vocesKeepLoaded;

  /// For an attached .gguf: the chat format to use instead of the one in
  /// the file (a [ChatFormat] name). Null means automatic. Catalog models
  /// always use their own.
  final String? chatFormat;

  /// For an attached .gguf: its vision file (mmproj), which lets the model
  /// see pictures. Catalog models that can see bring their own.
  final String? mmprojPath;

  /// Overrides the model's recommended temperature. Null means recommended.
  final double? temperature;

  /// External mode: base URL of any OpenAI-compatible server (Ollama, LM Studio, llama.cpp…).
  final String llmEndpoint;
  final String llmModel;

  /// Only needed for remote endpoints. Kept by [SecretStore] (the
  /// keyring, or sealed for the user), never in settings.json.
  final String llmApiKey;

  final String invokeUrl;
  final int accentColor;

  /// The companion's pick of background glows (ARGB, up to three) and where
  /// they sit (0 to 1). Empty and null mean the accent-based default.
  final List<int> backgroundColors;
  final double? backgroundLayout;

  /// A special colorway ([Look.special]) that also tints the window and
  /// panels; null for the standard ones.
  final String? colorway;

  /// Set by the human in Settings, or by the companion's set_theme.
  final ThemeChoice themeChoice;

  final StatusLight statusLight;

  final SettingsTabs settingsTabs;

  /// How big everything is drawn, on top of the computer's own scaling;
  /// 1 is as the computer says.
  final double interfaceScale;

  /// The volume videos in Pictures play at, 0-100, as last set.
  final double videoVolume;

  /// Whether a video portrait plays; off, its still picture shows.
  final bool playVideoPortraits;

  /// Whether a portrait's 18+ version shows, when it has one.
  final bool showNsfwAvatar;

  /// How much the background picture is darkened (or lightened in the
  /// light theme), from 0.3 to 0.9.
  final double backgroundDim;

  /// Lets the companion run commands and open things on this computer, each
  /// time with the human's OK. Off until the human turns it on.
  final bool systemAccess;

  /// Requests the human allowed always, e.g. `run: git status` or
  /// `open: https://example.com`; matched exactly.
  final List<String> allowedSystemActions;

  /// With system access on, commands and opens run without asking. Off
  /// unless the human accepted the warning.
  final bool allowEverything;

  /// Which database holds the current companion's chats and memories.
  /// Null for the first companion, whose database is `companion.db`.
  final String? companionId;

  /// The companions not being talked to right now, ready to switch to. The
  /// current one is the companion fields above.
  final List<CompanionProfile> otherCompanions;

  /// Whether the human has seen that VoxCordis is meant for one companion,
  /// shown the first time they add another.
  final bool toldAboutMoreCompanions;

  /// Whether the human agreed that pictures they share go to the
  /// server-hosted brain, asked the first time one would.
  final bool picturesToServerOk;

  /// Lets the companion search the web and read pages. Off until the human
  /// turns it on in Settings → Internet.
  final bool internetAccess;

  /// Lets the companion use its own browser, without a window, for sites
  /// that need clicking and typing.
  final bool companionBrowser;
  final SearchProvider searchProvider;

  /// The SearXNG instance, e.g. `https://searx.example.org`.
  final String searxngUrl;

  /// The Brave or Tavily key. Kept by [SecretStore], never in
  /// settings.json.
  final String searchApiKey;

  /// Sites the companion never visits, e.g. `facebook.com`.
  final List<String> blockedSites;

  /// Closing the window keeps VoxCordis running in the background, so
  /// reminders and automations still happen.
  final bool keepRunning;

  /// Writes what the browser, the web tools, the brain and drawing do to
  /// Settings → Logs, kept in the companion's database.
  final bool keepLogs;

  /// Voces Mundi, the roleplay mode, shows as a row in the companion
  /// menu. Off by default, so people who only want a companion never see
  /// it.
  final bool vocesMundi;

  /// 18+ worlds, their extra tags and the narrator's adult rules show in
  /// Voces Mundi. Off by default; turned on after an age check.
  final bool vocesMature;

  /// A story shows its latest scene picture (else its world's) dimmed
  /// behind the turns.
  final bool vocesBackdrop;

  /// The kinds of log line not written (LogKind names), while [keepLogs]
  /// is on.
  final List<String> logsOff;

  /// Whether VoxCordis starts when the human logs in, and whether its window
  /// shows or is put away.
  final StartMode startMode;

  bool get startWithComputer => startMode != StartMode.off;

  /// What the window opens to when the app starts.
  final OpenOnStart openOnStart;

  /// Voces Mundi was open when the app was last closed.
  final bool lastInVoces;

  /// Most automation runs a day, so a mistake can't run up a bill with a
  /// server-hosted brain.
  final int automationRunsPerDay;

  /// Whether the companion can draw, and with what.
  final ImageEngineChoice imageEngine;

  /// The picture model used when the companion doesn't pick one: a
  /// catalog id, or the file name of one of the human's own.
  final String? imageModel;

  /// Unloads the built-in chat model while a picture is drawn, so the
  /// picture model has the graphics card to itself.
  final bool freeGpuForDrawing;

  /// What the Pictures tab's draw panel was left showing.
  final DrawPanelPrefs draw;

  /// Hours of silence before the companion does something on its own (a
  /// poke), or 0 for never.
  final int pokeAfterHours;

  /// No pokes from this hour until [pokeQuietUntil]; the same hour for
  /// both means no quiet hours.
  final int pokeQuietFrom;
  final int pokeQuietUntil;

  /// Keep poking every [pokeAfterHours] while the human is away, instead
  /// of once until they write again.
  final bool pokeRepeat;

  /// The current companion, as it would be stored while another is talked
  /// to.
  CompanionProfile get currentCompanion => CompanionProfile(
    id: companionId,
    name: companionName,
    pronouns: pronouns,
    traits: traits,
    portraitPath: portraitPath,
    folder: companionFolder!,
    accentColor: accentColor,
    backgroundColors: backgroundColors,
    backgroundLayout: backgroundLayout,
    colorway: colorway,
  );

  /// These settings once the current companion is gone: talking to the
  /// first of the others, or with no companion at all (which sends the
  /// app back to setup) when it was the only one.
  AppSettings withoutCurrent() {
    if (otherCompanions.isEmpty) {
      return copyWith(
        clearFolder: true,
        clearPortrait: true,
        clearBackground: true,
        otherCompanions: const [],
        // Who the next first companion is starts afresh too, not as the
        // deleted one's leftovers.
        companionName: const AppSettings().companionName,
        pronouns: const AppSettings().pronouns,
        traits: const AppSettings().traits,
        accentColor: const AppSettings().accentColor,
      );
    }
    final next = otherCompanions.first;
    final s = switchedTo(next);
    return s.copyWith(
      otherCompanions: [
        for (final o in s.otherCompanions)
          if (o.folder != currentCompanion.folder) o,
      ],
    );
  }

  /// Every companion, the current one first.
  List<CompanionProfile> get companions => [
    if (companionFolder != null) currentCompanion,
    ...otherCompanions,
  ];

  /// These settings talking to [c] instead, with the current companion put
  /// aside among the others.
  AppSettings switchedTo(CompanionProfile c) {
    final others = [
      for (final o in otherCompanions)
        if (o.folder != c.folder) o,
      if (companionFolder != null && companionFolder != c.folder)
        currentCompanion,
    ];
    return AppSettings(
      companionName: c.name,
      pronouns: c.pronouns,
      traits: c.traits,
      userName: userName,
      userPronouns: userPronouns,
      portraitPath: c.portraitPath,
      companionFolder: c.folder,
      llmMode: llmMode,
      modelPath: modelPath,
      modelsFolder: modelsFolder,
      contextSize: contextSize,
      useGpu: useGpu,
      freeGpuWhenIdle: freeGpuWhenIdle,
      idleMinutes: idleMinutes,
      vocesKeepLoaded: vocesKeepLoaded,
      chatFormat: chatFormat,
      mmprojPath: mmprojPath,
      temperature: temperature,
      llmEndpoint: llmEndpoint,
      llmModel: llmModel,
      llmApiKey: llmApiKey,
      invokeUrl: invokeUrl,
      accentColor: c.accentColor,
      backgroundColors: c.backgroundColors,
      backgroundLayout: c.backgroundLayout,
      colorway: c.colorway,
      themeChoice: themeChoice,
      statusLight: statusLight,
      settingsTabs: settingsTabs,
      backgroundDim: backgroundDim,
      interfaceScale: interfaceScale,
      videoVolume: videoVolume,
      playVideoPortraits: playVideoPortraits,
      showNsfwAvatar: showNsfwAvatar,
      systemAccess: systemAccess,
      allowedSystemActions: allowedSystemActions,
      allowEverything: allowEverything,
      companionId: c.id,
      otherCompanions: others,
      toldAboutMoreCompanions: toldAboutMoreCompanions,
      picturesToServerOk: picturesToServerOk,
      internetAccess: internetAccess,
      companionBrowser: companionBrowser,
      searchProvider: searchProvider,
      searxngUrl: searxngUrl,
      searchApiKey: searchApiKey,
      blockedSites: blockedSites,
      keepRunning: keepRunning,
      keepLogs: keepLogs,
      vocesMundi: vocesMundi,
      vocesMature: vocesMature,
      vocesBackdrop: vocesBackdrop,
      logsOff: logsOff,
      startMode: startMode,
      openOnStart: openOnStart,
      lastInVoces: lastInVoces,
      automationRunsPerDay: automationRunsPerDay,
      imageEngine: imageEngine,
      imageModel: imageModel,
      freeGpuForDrawing: freeGpuForDrawing,
      draw: draw,
      pokeAfterHours: pokeAfterHours,
      pokeQuietFrom: pokeQuietFrom,
      pokeQuietUntil: pokeQuietUntil,
      pokeRepeat: pokeRepeat,
    );
  }

  bool get isSetUp =>
      companionFolder != null &&
      switch (llmMode) {
        LlmMode.builtIn => modelPath != null,
        LlmMode.external => llmModel.isNotEmpty,
      };

  AppSettings copyWith({
    String? companionName,
    String? pronouns,
    List<String>? traits,
    String? userName,
    String? userPronouns,
    String? portraitPath,
    String? companionFolder,
    LlmMode? llmMode,
    String? modelPath,
    String? modelsFolder,
    int? contextSize,
    bool? useGpu,
    bool? freeGpuWhenIdle,
    int? idleMinutes,
    bool? vocesKeepLoaded,
    String? chatFormat,
    String? mmprojPath,
    double? temperature,
    String? llmEndpoint,
    String? llmModel,
    String? llmApiKey,
    String? invokeUrl,
    int? accentColor,
    List<int>? backgroundColors,
    double? backgroundLayout,
    String? colorway,
    ThemeChoice? themeChoice,
    StatusLight? statusLight,
    SettingsTabs? settingsTabs,
    double? backgroundDim,
    double? interfaceScale,
    double? videoVolume,
    bool? playVideoPortraits,
    bool? showNsfwAvatar,
    bool? systemAccess,
    List<String>? allowedSystemActions,
    bool? allowEverything,
    List<CompanionProfile>? otherCompanions,
    bool? toldAboutMoreCompanions,
    bool? picturesToServerOk,
    bool? internetAccess,
    bool? companionBrowser,
    SearchProvider? searchProvider,
    String? searxngUrl,
    String? searchApiKey,
    List<String>? blockedSites,
    bool? keepRunning,
    bool? keepLogs,
    bool? vocesMundi,
    bool? vocesMature,
    bool? vocesBackdrop,
    List<String>? logsOff,
    StartMode? startMode,
    OpenOnStart? openOnStart,
    bool? lastInVoces,
    int? automationRunsPerDay,
    ImageEngineChoice? imageEngine,
    String? imageModel,
    bool? freeGpuForDrawing,
    DrawPanelPrefs? draw,
    int? pokeAfterHours,
    int? pokeQuietFrom,
    int? pokeQuietUntil,
    bool? pokeRepeat,
    bool clearPortrait = false,
    bool clearChatFormat = false,
    bool clearMmproj = false,
    bool clearTemperature = false,
    bool clearBackground = false,
    bool clearFolder = false,
  }) {
    return AppSettings(
      companionName: companionName ?? this.companionName,
      pronouns: pronouns ?? this.pronouns,
      traits: traits ?? this.traits,
      userName: userName ?? this.userName,
      userPronouns: userPronouns ?? this.userPronouns,
      portraitPath: clearPortrait ? null : portraitPath ?? this.portraitPath,
      companionFolder: clearFolder
          ? null
          : companionFolder ?? this.companionFolder,
      llmMode: llmMode ?? this.llmMode,
      modelPath: modelPath ?? this.modelPath,
      modelsFolder: modelsFolder ?? this.modelsFolder,
      contextSize: contextSize ?? this.contextSize,
      useGpu: useGpu ?? this.useGpu,
      freeGpuWhenIdle: freeGpuWhenIdle ?? this.freeGpuWhenIdle,
      idleMinutes: idleMinutes ?? this.idleMinutes,
      vocesKeepLoaded: vocesKeepLoaded ?? this.vocesKeepLoaded,
      chatFormat: clearChatFormat ? null : chatFormat ?? this.chatFormat,
      mmprojPath: clearMmproj ? null : mmprojPath ?? this.mmprojPath,
      temperature: clearTemperature ? null : temperature ?? this.temperature,
      llmEndpoint: llmEndpoint ?? this.llmEndpoint,
      llmModel: llmModel ?? this.llmModel,
      llmApiKey: llmApiKey ?? this.llmApiKey,
      invokeUrl: invokeUrl ?? this.invokeUrl,
      accentColor: accentColor ?? this.accentColor,
      backgroundColors: clearBackground
          ? const []
          : backgroundColors ?? this.backgroundColors,
      backgroundLayout: clearBackground
          ? null
          : backgroundLayout ?? this.backgroundLayout,
      // '' takes it off.
      colorway: clearBackground || colorway == ''
          ? null
          : colorway ?? this.colorway,
      themeChoice: themeChoice ?? this.themeChoice,
      statusLight: statusLight ?? this.statusLight,
      settingsTabs: settingsTabs ?? this.settingsTabs,
      backgroundDim: backgroundDim ?? this.backgroundDim,
      interfaceScale: interfaceScale ?? this.interfaceScale,
      videoVolume: videoVolume ?? this.videoVolume,
      playVideoPortraits: playVideoPortraits ?? this.playVideoPortraits,
      showNsfwAvatar: showNsfwAvatar ?? this.showNsfwAvatar,
      systemAccess: systemAccess ?? this.systemAccess,
      allowedSystemActions: allowedSystemActions ?? this.allowedSystemActions,
      allowEverything: allowEverything ?? this.allowEverything,
      companionId: clearFolder ? null : companionId,
      otherCompanions: otherCompanions ?? this.otherCompanions,
      toldAboutMoreCompanions:
          toldAboutMoreCompanions ?? this.toldAboutMoreCompanions,
      picturesToServerOk: picturesToServerOk ?? this.picturesToServerOk,
      internetAccess: internetAccess ?? this.internetAccess,
      companionBrowser: companionBrowser ?? this.companionBrowser,
      searchProvider: searchProvider ?? this.searchProvider,
      searxngUrl: searxngUrl ?? this.searxngUrl,
      searchApiKey: searchApiKey ?? this.searchApiKey,
      blockedSites: blockedSites ?? this.blockedSites,
      keepRunning: keepRunning ?? this.keepRunning,
      keepLogs: keepLogs ?? this.keepLogs,
      vocesMundi: vocesMundi ?? this.vocesMundi,
      vocesMature: vocesMature ?? this.vocesMature,
      vocesBackdrop: vocesBackdrop ?? this.vocesBackdrop,
      logsOff: logsOff ?? this.logsOff,
      startMode: startMode ?? this.startMode,
      openOnStart: openOnStart ?? this.openOnStart,
      lastInVoces: lastInVoces ?? this.lastInVoces,
      automationRunsPerDay: automationRunsPerDay ?? this.automationRunsPerDay,
      imageEngine: imageEngine ?? this.imageEngine,
      imageModel: imageModel ?? this.imageModel,
      freeGpuForDrawing: freeGpuForDrawing ?? this.freeGpuForDrawing,
      draw: draw ?? this.draw,
      pokeAfterHours: pokeAfterHours ?? this.pokeAfterHours,
      pokeQuietFrom: pokeQuietFrom ?? this.pokeQuietFrom,
      pokeQuietUntil: pokeQuietUntil ?? this.pokeQuietUntil,
      pokeRepeat: pokeRepeat ?? this.pokeRepeat,
    );
  }

  Map<String, Object?> toJson() => {
    'companionName': companionName,
    'pronouns': pronouns,
    'traits': traits,
    'userName': userName,
    'userPronouns': userPronouns,
    'portraitPath': portraitPath,
    'companionFolder': companionFolder,
    'llmMode': llmMode.name,
    'modelPath': modelPath,
    'modelsFolder': modelsFolder,
    'contextSize': contextSize,
    'useGpu': useGpu,
    'freeGpuWhenIdle': freeGpuWhenIdle,
    'idleMinutes': idleMinutes,
    'vocesKeepLoaded': vocesKeepLoaded,
    'chatFormat': chatFormat,
    'mmprojPath': mmprojPath,
    'temperature': temperature,
    'llmEndpoint': llmEndpoint,
    'llmModel': llmModel,
    'invokeUrl': invokeUrl,
    'accentColor': accentColor,
    'backgroundColors': backgroundColors,
    'backgroundLayout': backgroundLayout,
    'colorway': colorway,
    'themeChoice': themeChoice.name,
    'statusLight': statusLight.name,
    'settingsTabs': settingsTabs.name,
    'backgroundDim': backgroundDim,
    'interfaceScale': interfaceScale,
    'videoVolume': videoVolume,
    'playVideoPortraits': playVideoPortraits,
    'showNsfwAvatar': showNsfwAvatar,
    'systemAccess': systemAccess,
    'allowedSystemActions': allowedSystemActions,
    'allowEverything': allowEverything,
    'companionId': companionId,
    'otherCompanions': [for (final c in otherCompanions) c.toJson()],
    'toldAboutMoreCompanions': toldAboutMoreCompanions,
    'picturesToServerOk': picturesToServerOk,
    'internetAccess': internetAccess,
    'companionBrowser': companionBrowser,
    'searchProvider': searchProvider.name,
    'searxngUrl': searxngUrl,
    'blockedSites': blockedSites,
    'keepRunning': keepRunning,
    'keepLogs': keepLogs,
    'vocesMundi': vocesMundi,
    'vocesMature': vocesMature,
    'vocesBackdrop': vocesBackdrop,
    'logsOff': logsOff,
    'startMode': startMode.name,
    'openOnStart': openOnStart.name,
    'lastInVoces': lastInVoces,
    'automationRunsPerDay': automationRunsPerDay,
    'imageEngine': imageEngine.name,
    'imageModel': imageModel,
    'freeGpuForDrawing': freeGpuForDrawing,
    'draw': draw.toJson(),
    'pokeAfterHours': pokeAfterHours,
    'pokeQuietFrom': pokeQuietFrom,
    'pokeQuietUntil': pokeQuietUntil,
    'pokeRepeat': pokeRepeat,
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    const d = AppSettings();
    return AppSettings(
      companionName: json['companionName'] as String? ?? d.companionName,
      pronouns: json['pronouns'] as String? ?? d.pronouns,
      traits: (json['traits'] as List?)?.cast<String>() ?? d.traits,
      userName: json['userName'] as String? ?? d.userName,
      userPronouns: json['userPronouns'] as String? ?? d.userPronouns,
      portraitPath: json['portraitPath'] as String?,
      companionFolder: json['companionFolder'] as String?,
      // Settings from before the built-in runtime used an external server.
      llmMode:
          LlmMode.values.asNameMap()[json['llmMode']] ??
          ((json['llmModel'] as String? ?? '').isNotEmpty
              ? LlmMode.external
              : LlmMode.builtIn),
      modelPath: json['modelPath'] as String?,
      modelsFolder: json['modelsFolder'] as String?,
      contextSize: json['contextSize'] as int? ?? d.contextSize,
      useGpu: json['useGpu'] as bool? ?? d.useGpu,
      freeGpuWhenIdle: json['freeGpuWhenIdle'] as bool? ?? false,
      idleMinutes: (json['idleMinutes'] as num?)?.toInt() ?? 1,
      vocesKeepLoaded: json['vocesKeepLoaded'] as bool? ?? true,
      chatFormat: json['chatFormat'] as String?,
      mmprojPath: json['mmprojPath'] as String?,
      temperature: (json['temperature'] as num?)?.toDouble(),
      llmEndpoint: json['llmEndpoint'] as String? ?? d.llmEndpoint,
      llmModel: json['llmModel'] as String? ?? d.llmModel,
      // Only in files from before [SecretStore]; moved out on load.
      llmApiKey: json['llmApiKey'] as String? ?? d.llmApiKey,
      invokeUrl: json['invokeUrl'] as String? ?? d.invokeUrl,
      accentColor: json['accentColor'] as int? ?? d.accentColor,
      backgroundColors:
          (json['backgroundColors'] as List?)?.whereType<int>().toList() ??
          const [],
      backgroundLayout: (json['backgroundLayout'] as num?)?.toDouble(),
      colorway: json['colorway'] as String?,
      themeChoice:
          ThemeChoice.values.asNameMap()[json['themeChoice']] ?? d.themeChoice,
      statusLight:
          StatusLight.values.asNameMap()[json['statusLight']] ?? d.statusLight,
      settingsTabs:
          SettingsTabs.values.asNameMap()[json['settingsTabs']] ??
          d.settingsTabs,
      backgroundDim:
          ((json['backgroundDim'] as num?)?.toDouble() ?? d.backgroundDim)
              .clamp(0.3, 0.9),
      videoVolume: ((json['videoVolume'] as num?)?.toDouble() ?? d.videoVolume)
          .clamp(0, 100)
          .toDouble(),
      interfaceScale:
          ((json['interfaceScale'] as num?)?.toDouble() ?? d.interfaceScale)
              .clamp(minInterfaceScale, maxInterfaceScale),
      playVideoPortraits: json['playVideoPortraits'] as bool? ?? true,
      showNsfwAvatar: json['showNsfwAvatar'] as bool? ?? false,
      systemAccess: json['systemAccess'] as bool? ?? false,
      allowEverything: json['allowEverything'] as bool? ?? false,
      allowedSystemActions:
          (json['allowedSystemActions'] as List?)?.cast<String>() ?? const [],
      companionId: json['companionId'] as String?,
      otherCompanions: [
        for (final c in json['otherCompanions'] as List? ?? const [])
          if (c is Map<String, Object?> && c['folder'] is String)
            CompanionProfile.fromJson(c),
      ],
      toldAboutMoreCompanions:
          json['toldAboutMoreCompanions'] as bool? ?? false,
      picturesToServerOk: json['picturesToServerOk'] as bool? ?? false,
      internetAccess: json['internetAccess'] as bool? ?? false,
      companionBrowser: json['companionBrowser'] as bool? ?? false,
      searchProvider:
          SearchProvider.values.asNameMap()[json['searchProvider']] ??
          d.searchProvider,
      searxngUrl: json['searxngUrl'] as String? ?? '',
      blockedSites:
          (json['blockedSites'] as List?)?.whereType<String>().toList() ??
          const [],
      keepRunning: json['keepRunning'] as bool? ?? false,
      keepLogs: json['keepLogs'] as bool? ?? true,
      vocesMundi: json['vocesMundi'] as bool? ?? false,
      vocesMature: json['vocesMature'] as bool? ?? false,
      vocesBackdrop: json['vocesBackdrop'] as bool? ?? true,
      logsOff:
          (json['logsOff'] as List?)?.whereType<String>().toList() ?? const [],
      // Before the choice there was a switch, which always started hidden.
      startMode:
          StartMode.values.asNameMap()[json['startMode']] ??
          (json['startWithComputer'] == true
              ? StartMode.minimized
              : StartMode.off),
      openOnStart:
          OpenOnStart.values.asNameMap()[json['openOnStart']] ??
          OpenOnStart.lastPlace,
      lastInVoces: json['lastInVoces'] as bool? ?? false,
      automationRunsPerDay:
          json['automationRunsPerDay'] as int? ?? d.automationRunsPerDay,
      imageEngine:
          ImageEngineChoice.values.asNameMap()[json['imageEngine']] ??
          d.imageEngine,
      imageModel: json['imageModel'] as String?,
      freeGpuForDrawing:
          json['freeGpuForDrawing'] as bool? ?? d.freeGpuForDrawing,
      draw: DrawPanelPrefs.fromJson(json['draw']),
      pokeAfterHours: json['pokeAfterHours'] as int? ?? d.pokeAfterHours,
      pokeQuietFrom: json['pokeQuietFrom'] as int? ?? d.pokeQuietFrom,
      pokeQuietUntil: json['pokeQuietUntil'] as int? ?? d.pokeQuietUntil,
      pokeRepeat: json['pokeRepeat'] as bool? ?? d.pokeRepeat,
    );
  }
}

/// A companion's own part of the settings: who it is, where it lives and
/// how it styled the app. Everything else (the human, the brain, system
/// access) is shared by all companions.
@immutable
class CompanionProfile {
  const CompanionProfile({
    required this.id,
    required this.name,
    required this.folder,
    this.pronouns = 'she/her',
    this.traits = const [],
    this.portraitPath,
    this.accentColor = 0xFFB18CFF,
    this.backgroundColors = const [],
    this.backgroundLayout,
    this.colorway,
  });

  /// See [AppSettings.companionId].
  final String? id;
  final String name;
  final String folder;
  final String pronouns;
  final List<String> traits;
  final String? portraitPath;
  final int accentColor;
  final List<int> backgroundColors;
  final double? backgroundLayout;

  /// A special colorway ([Look.special]) that also tints the window and
  /// panels; null for the standard ones.
  final String? colorway;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'folder': folder,
    'pronouns': pronouns,
    'traits': traits,
    'portraitPath': portraitPath,
    'accentColor': accentColor,
    'backgroundColors': backgroundColors,
    'backgroundLayout': backgroundLayout,
    'colorway': colorway,
  };

  factory CompanionProfile.fromJson(Map<String, Object?> json) {
    const d = AppSettings();
    return CompanionProfile(
      id: json['id'] as String?,
      name: json['name'] as String? ?? d.companionName,
      folder: json['folder'] as String,
      pronouns: json['pronouns'] as String? ?? d.pronouns,
      traits:
          (json['traits'] as List?)?.whereType<String>().toList() ?? const [],
      portraitPath: json['portraitPath'] as String?,
      accentColor: json['accentColor'] as int? ?? d.accentColor,
      backgroundColors:
          (json['backgroundColors'] as List?)?.whereType<int>().toList() ??
          const [],
      backgroundLayout: (json['backgroundLayout'] as num?)?.toDouble(),
      colorway: json['colorway'] as String?,
    );
  }
}

/// Holds the current settings and persists them to `settings.json` in the
/// app's support directory (not the companion folder, so the folder can move).
/// The API key goes to [secrets] instead.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._file, this._value, {this.secrets})
    : _savedKey = _value.llmApiKey,
      _savedSearchKey = _value.searchApiKey;

  final File _file;
  AppSettings _value;

  /// Where the API key is kept; null (in tests) keeps it in memory only.
  final SecretStore? secrets;

  /// The key as [secrets] holds it, so a save only touches the keyring
  /// when the key changed.
  String _savedKey;
  String _savedSearchKey;

  AppSettings get value => _value;

  static const apiKeySecret = 'llm-api-key';
  static const searchKeySecret = 'search-api-key';

  static Future<SettingsStore> load(
    Directory supportDir, {
    SecretStore? secrets,
  }) async {
    final file = File(p.join(supportDir.path, 'settings.json'));
    final store =
        secrets ?? SecretStore(Directory(p.join(supportDir.path, 'secrets')));
    var settings = const AppSettings();
    var keyInFile = false;
    if (await file.exists()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        keyInFile = json.containsKey('llmApiKey');
        settings = AppSettings.fromJson(json);
      } catch (_) {
        // A broken file falls back to defaults rather than blocking startup.
      }
    }
    if (keyInFile) {
      // Older versions kept the key in settings.json: move it out, then
      // save the file again without it.
      final s = SettingsStore(file, settings, secrets: store).._savedKey = '';
      try {
        await s.update(settings);
      } catch (_) {
        // Tried again on the next save.
      }
      return s;
    }
    final key = await store.read(apiKeySecret) ?? '';
    final searchKey = await store.read(searchKeySecret) ?? '';
    return SettingsStore(
      file,
      settings.copyWith(
        llmApiKey: key.isEmpty ? null : key,
        searchApiKey: searchKey.isEmpty ? null : searchKey,
      ),
      secrets: store,
    );
  }

  Future<void> update(AppSettings next) async {
    _value = next;
    notifyListeners();
    // One save at a time, each written beside the file and then swapped in,
    // so a crash mid-save can't leave a half-written file (which would send
    // the app back to setup).
    final write = _saving.then((_) async {
      final s = _value;
      final secrets = this.secrets;
      if (secrets != null && s.llmApiKey != _savedKey) {
        await secrets.write(apiKeySecret, s.llmApiKey);
        _savedKey = s.llmApiKey;
      }
      if (secrets != null && s.searchApiKey != _savedSearchKey) {
        await secrets.write(searchKeySecret, s.searchApiKey);
        _savedSearchKey = s.searchApiKey;
      }
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString('', flush: true);
      await restrictToOwner(tmp.path);
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(s.toJson()),
        flush: true,
      );
      await tmp.rename(_file.path);
    });
    _saving = write.catchError((_) {});
    await write;
  }

  Future<void> _saving = Future.value();
}
