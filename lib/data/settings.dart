import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/secret_store.dart';

enum LlmMode { builtIn, external }

/// Light or dark look. System follows the OS, and is dark when the OS
/// doesn't say.
enum ThemeChoice { system, light, dark }

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
    this.chatFormat,
    this.temperature,
    this.llmEndpoint = 'http://localhost:11434/v1',
    this.llmModel = '',
    this.llmApiKey = '',
    this.invokeUrl = 'http://localhost:9090',
    this.accentColor = 0xFFB18CFF,
    this.backgroundColors = const [],
    this.backgroundLayout,
    this.themeChoice = ThemeChoice.system,
    this.systemAccess = false,
    this.allowedSystemActions = const [],
    this.companionId,
    this.otherCompanions = const [],
    this.toldAboutMoreCompanions = false,
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

  /// For an attached .gguf: the chat format to use instead of the one in
  /// the file (a [ChatFormat] name). Null means automatic. Catalog models
  /// always use their own.
  final String? chatFormat;

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

  /// Set by the human in Settings, or by the companion's set_theme.
  final ThemeChoice themeChoice;

  /// Lets the companion run commands and open things on this computer, each
  /// time with the human's OK. Off until the human turns it on.
  final bool systemAccess;

  /// Requests the human allowed always, e.g. `run: git status` or
  /// `open: https://example.com`; matched exactly.
  final List<String> allowedSystemActions;

  /// Which database holds the current companion's chats and memories.
  /// Null for the first companion, whose database is `companion.db`.
  final String? companionId;

  /// The companions not being talked to right now, ready to switch to. The
  /// current one is the companion fields above.
  final List<CompanionProfile> otherCompanions;

  /// Whether the human has seen that VoxCordis is meant for one companion,
  /// shown the first time they add another.
  final bool toldAboutMoreCompanions;

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
  );

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
      chatFormat: chatFormat,
      temperature: temperature,
      llmEndpoint: llmEndpoint,
      llmModel: llmModel,
      llmApiKey: llmApiKey,
      invokeUrl: invokeUrl,
      accentColor: c.accentColor,
      backgroundColors: c.backgroundColors,
      backgroundLayout: c.backgroundLayout,
      themeChoice: themeChoice,
      systemAccess: systemAccess,
      allowedSystemActions: allowedSystemActions,
      companionId: c.id,
      otherCompanions: others,
      toldAboutMoreCompanions: toldAboutMoreCompanions,
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
    String? chatFormat,
    double? temperature,
    String? llmEndpoint,
    String? llmModel,
    String? llmApiKey,
    String? invokeUrl,
    int? accentColor,
    List<int>? backgroundColors,
    double? backgroundLayout,
    ThemeChoice? themeChoice,
    bool? systemAccess,
    List<String>? allowedSystemActions,
    List<CompanionProfile>? otherCompanions,
    bool? toldAboutMoreCompanions,
    bool clearPortrait = false,
    bool clearChatFormat = false,
    bool clearTemperature = false,
    bool clearBackground = false,
  }) {
    return AppSettings(
      companionName: companionName ?? this.companionName,
      pronouns: pronouns ?? this.pronouns,
      traits: traits ?? this.traits,
      userName: userName ?? this.userName,
      userPronouns: userPronouns ?? this.userPronouns,
      portraitPath: clearPortrait ? null : portraitPath ?? this.portraitPath,
      companionFolder: companionFolder ?? this.companionFolder,
      llmMode: llmMode ?? this.llmMode,
      modelPath: modelPath ?? this.modelPath,
      modelsFolder: modelsFolder ?? this.modelsFolder,
      contextSize: contextSize ?? this.contextSize,
      useGpu: useGpu ?? this.useGpu,
      chatFormat: clearChatFormat ? null : chatFormat ?? this.chatFormat,
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
      themeChoice: themeChoice ?? this.themeChoice,
      systemAccess: systemAccess ?? this.systemAccess,
      allowedSystemActions: allowedSystemActions ?? this.allowedSystemActions,
      companionId: companionId,
      otherCompanions: otherCompanions ?? this.otherCompanions,
      toldAboutMoreCompanions:
          toldAboutMoreCompanions ?? this.toldAboutMoreCompanions,
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
    'chatFormat': chatFormat,
    'temperature': temperature,
    'llmEndpoint': llmEndpoint,
    'llmModel': llmModel,
    'invokeUrl': invokeUrl,
    'accentColor': accentColor,
    'backgroundColors': backgroundColors,
    'backgroundLayout': backgroundLayout,
    'themeChoice': themeChoice.name,
    'systemAccess': systemAccess,
    'allowedSystemActions': allowedSystemActions,
    'companionId': companionId,
    'otherCompanions': [for (final c in otherCompanions) c.toJson()],
    'toldAboutMoreCompanions': toldAboutMoreCompanions,
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
      chatFormat: json['chatFormat'] as String?,
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
      themeChoice:
          ThemeChoice.values.asNameMap()[json['themeChoice']] ?? d.themeChoice,
      systemAccess: json['systemAccess'] as bool? ?? false,
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
    );
  }
}

/// Holds the current settings and persists them to `settings.json` in the
/// app's support directory (not the companion folder, so the folder can move).
/// The API key goes to [secrets] instead.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._file, this._value, {this.secrets})
    : _savedKey = _value.llmApiKey;

  final File _file;
  AppSettings _value;

  /// Where the API key is kept; null (in tests) keeps it in memory only.
  final SecretStore? secrets;

  /// The key as [secrets] holds it, so a save only touches the keyring
  /// when the key changed.
  String _savedKey;

  AppSettings get value => _value;

  static const apiKeySecret = 'llm-api-key';

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
    return SettingsStore(
      file,
      key.isEmpty ? settings : settings.copyWith(llmApiKey: key),
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
