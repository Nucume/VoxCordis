import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/core_rules.dart';
import '../../data/desk/desk_files.dart';
import '../../data/desk/pictures.dart';
import '../../data/looks.dart';
import '../../data/settings.dart';
import '../../services/folder_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import '../../services/changelog.dart';
import '../../services/updater.dart';
import '../setup/character_pickers.dart';
import '../update/update_dialog.dart';
import 'delete_companion_dialog.dart';
import 'encryption_settings.dart';
import 'image_settings.dart';
import 'internet_settings.dart';
import 'logs_settings.dart';
import '../update/whats_new_dialog.dart';
import 'model_picker.dart';
import '../../shell/window_frame.dart';
import '../../shell/runtime_status.dart';
import 'recall_settings.dart';
import 'sight_settings.dart';

/// Minimal v1 Settings: General, Brain (the model) and Images. Other tabs arrive with the systems
/// they control.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialTab = 0});

  /// The page to open on, e.g. [privacyTab].
  final int initialTab;

  /// Privacy: the encryption key ([EncryptionSettings]).
  static const appearanceTab = 1;
  static const imagesTab = 2;
  static const brainTab = 3;
  static const internetTab = 5;
  static const privacyTab = 6;
  static const logsTab = 7;

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _draft;
  late final _userName = TextEditingController();
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _draft = AppScope.of(context).settings.value;
    _userName.text = _draft.userName;
  }

  @override
  void dispose() {
    _userName.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
    if (path == null) return;
    setState(() => _draft = _draft.copyWith(companionFolder: path));
  }

  /// What Save would store: this page's copy, minus what is changed
  /// elsewhere while it is open.
  AppSettings _merged(AppSettings current) => _draft.copyWith(
    // After setup name, pronouns, traits and portrait are the companion's
    // own; keep what it last saved, not this page's copy.
    companionName: current.companionName,
    traits: current.traits,
    pronouns: current.pronouns,
    portraitPath: current.portraitPath,
    // System access applies at once on its page, and "Always allow" in
    // the chat adds to the list while this page is open.
    systemAccess: current.systemAccess,
    // Logs turn on and off at once on their page.
    keepLogs: current.keepLogs,
    logsOff: current.logsOff,
    allowedSystemActions: current.allowedSystemActions,
    // Switching and adding companions happen outside this page.
    otherCompanions: current.otherCompanions,
    toldAboutMoreCompanions: current.toldAboutMoreCompanions,
    // The look applies at once, and the companion may restyle it.
    accentColor: current.accentColor,
    backgroundColors: current.backgroundColors,
    backgroundLayout: current.backgroundLayout,
    colorway: current.colorway ?? '',
    themeChoice: current.themeChoice,
    statusLight: current.statusLight,
    backgroundDim: current.backgroundDim,
    clearBackground:
        current.backgroundColors.isEmpty && current.backgroundLayout == null,
    userName: _userName.text.trim(),
  );

  /// Whether leaving now would lose something changed on this page.
  bool get changed {
    final current = AppScope.of(context).settings.value;
    final next = _merged(current);
    if (next.llmApiKey != current.llmApiKey ||
        next.searchApiKey != current.searchApiKey) {
      return true;
    }
    final a = next.toJson();
    final b = current.toJson();
    // Without a model the Brain page sizes the span by itself on opening.
    if (next.modelPath == null) {
      a.remove('contextSize');
      b.remove('contextSize');
    }
    return jsonEncode(a) != jsonEncode(b);
  }

  /// Asked before the app leaves Settings: unsaved changes get Save,
  /// Discard or Cancel. True when it may go.
  Future<bool> mayLeave() async {
    if (!changed) return true;
    final choice = await showDialog<_Leave>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.save_outlined),
        title: const Text('Save your changes?'),
        content: const SizedBox(
          width: 380,
          child: Text(
            'Some settings were changed but not saved yet. Discarding '
            'puts them back the way they were.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _Leave.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _Leave.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _Leave.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    return switch (choice) {
      _Leave.save => await _save(),
      _Leave.discard => true,
      _Leave.cancel || null => false,
    };
  }

  /// True once saved; false when the human held back (the model won't fit).
  Future<bool> _save() async {
    final next = _merged(AppScope.of(context).settings.value);
    if (!await confirmModelFits(context, next)) return false;
    final folder = next.companionFolder;
    if (folder != null) {
      await CompanionFolder(folder).ensureExists();
      await CoreRules.load(next); // writes core.md the first time
      await DeskFiles.ensure(next);
    }
    if (!mounted) return false;
    final services = AppScope.of(context);
    services.runtime.touch(next);
    await services.settings.update(next);
    // Load the (possibly new) model in the background so chat is ready.
    services.runtime.ensureReady(next).ignore();
    if (!mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Row(
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            const Text('Settings saved'),
          ],
        ),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 9,
      initialIndex: widget.initialTab,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(text: 'General'),
                Tab(text: 'Appearance'),
                Tab(text: 'Images'),
                Tab(text: 'Brain'),
                Tab(text: 'Computer'),
                Tab(text: 'Internet'),
                Tab(text: 'Privacy'),
                Tab(text: 'Logs'),
                Tab(text: 'About'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _page(_general()),
                _page(_appearance()),
                _page([
                  ImageSettings(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                ]),
                _page([
                  const SizedBox(height: 14),
                  ModelPicker(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                  const SizedBox(height: 28),
                  SightSettings(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                  const SizedBox(height: 28),
                  RecallSettings(value: _draft),
                  const SizedBox(height: 28),
                  BrainAdvanced(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                ]),
                _page(const [_SystemAccess()]),
                _page([
                  InternetSettings(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                ]),
                _page(const [_Section('Encryption'), EncryptionSettings()]),
                _page(const [LogsSettings()]),
                _page(const [_About()]),
              ],
            ),
          ),
          // One Save for every page, so nothing is lost switching pages.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    children: children,
  );

  /// Colorway, background picture, theme and the ready light. The accent
  /// comes with the colorway, so it has no picker of its own.
  List<Widget> _appearance() {
    final name = _draft.companionName;
    return [
      const SizedBox(height: 14),
      _Colorways(
        onPicked: (look) => setState(
          () => _draft = _draft.copyWith(
            accentColor: look.accent,
            backgroundColors: look.colors,
            backgroundLayout: look.layout,
            colorway: look.isSpecial ? look.id : '',
          ),
        ),
      ),
      // The companion may have restyled the background into something no
      // colorway matches; this undoes it.
      if (_Colorways.current(_draft) == null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              setState(() => _draft = _draft.copyWith(clearBackground: true));
              final store = AppScope.of(context).settings;
              store.update(store.value.copyWith(clearBackground: true));
            },
            child: const Text('Reset the look'),
          ),
        ),
      const SizedBox(height: 14),
      const _BackgroundPicture(),
      const SizedBox(height: 14),
      Row(
        children: [
          Text('Theme', style: TextStyle(color: context.palette.textMuted)),
          const SizedBox(width: 12),
          // Applies at once, and follows the store: the companion may switch
          // it with set_theme while this page is open.
          ListenableBuilder(
            listenable: AppScope.of(context).settings,
            builder: (context, _) {
              final store = AppScope.of(context).settings;
              return SegmentedButton<ThemeChoice>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeChoice.system,
                    icon: Icon(Icons.brightness_auto_rounded),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: ThemeChoice.light,
                    icon: Icon(Icons.light_mode_rounded),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeChoice.dark,
                    icon: Icon(Icons.dark_mode_rounded),
                    label: Text('Dark'),
                  ),
                ],
                selected: {store.value.themeChoice},
                onSelectionChanged: (v) =>
                    store.update(store.value.copyWith(themeChoice: v.single)),
              );
            },
          ),
          const SizedBox(width: 8),
          InfoIcon(
            message:
                'System follows your computer, and is dark when it '
                "can't tell. $name can switch it too; pick again here to "
                'change it back.',
          ),
        ],
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Text(
            'Ready light',
            style: TextStyle(color: context.palette.textMuted),
          ),
          const SizedBox(width: 12),
          ListenableBuilder(
            listenable: AppScope.of(context).settings,
            builder: (context, _) {
              final store = AppScope.of(context).settings;
              return GlassSelect<StatusLight>(
                value: store.value.statusLight,
                options: [
                  for (final p in StatusLight.values)
                    GlassOption(p, RuntimeStatus.placeLabel(p)),
                ],
                onChanged: (v) =>
                    store.update(store.value.copyWith(statusLight: v)),
              );
            },
          ),
          const SizedBox(width: 8),
          const InfoIcon(
            message:
                'The light that shows whether the brain is loaded. You can '
                'also right-click the light to move it.',
          ),
        ],
      ),
      if (TitleBarChoice.supported) ...[
        const SizedBox(height: 6),
        ValueListenableBuilder<bool>(
          valueListenable: TitleBarChoice.system,
          builder: (context, system, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: system,
            onChanged: (on) => TitleBarChoice.set(systemBar: on),
            title: const Text('Use the system title bar'),
            subtitle: Text(
              Platform.isLinux
                  ? "Your desktop's own bar instead of the VoxCordis one. "
                        'Looks its best after a restart.'
                  : 'The Windows bar instead of the VoxCordis one.',
              style: TextStyle(fontSize: 12, color: context.palette.textMuted),
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _general() {
    final folder = _draft.companionFolder;
    final name = _draft.companionName;
    return [
      const _Section('You'),
      _field(
        _userName,
        'What should $name call you?',
        hint: 'Your name or a nickname',
      ),
      const SizedBox(height: 14),
      PronounPicker(
        value: _draft.userPronouns,
        optional: true,
        onChanged: (v) =>
            setState(() => _draft = _draft.copyWith(userPronouns: v)),
      ),
      _Section('In the background'),
      _Background(value: _draft, onChanged: (v) => setState(() => _draft = v)),
      _Poke(value: _draft, onChanged: (v) => setState(() => _draft = v)),
      _Section(name),
      _CompanionFiles(
        name: name,
        folder: folder,
        onChangeFolder: _pickFolder,
        onOpenFile: (file) async {
          await DeskFiles.ensure(_draft);
          await launchUrl(Uri.file(file.path));
        },
      ),
      const _Section('Danger zone'),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final (label, icon, action) in [
              (
                'Reset $name…',
                Icons.restart_alt_rounded,
                confirmResetCompanion,
              ),
              (
                'Delete $name…',
                Icons.delete_forever_rounded,
                confirmDeleteCompanion,
              ),
            ])
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(color: Theme.of(context).colorScheme.error),
                ),
                onPressed: () => action(context),
                icon: Icon(icon),
                label: Text(label),
              ),
          ],
        ),
      ),
      // Last on the page, apart from everything that only changes a setting.
      if (AppScope.of(context).background case final background?) ...[
        const SizedBox(height: 28),
        const Divider(height: 1),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: background.quit,
            icon: const Icon(Icons.power_settings_new_rounded),
            label: const Text('Quit VoxCordis'),
          ),
        ),
      ],
    ];
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

/// Close to the system tray, start with the computer, the
/// daily limit for tasks, and Quit.
class _Background extends StatelessWidget {
  const _Background({required this.value, required this.onChanged});

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  static const _limits = [5, 10, 24, 50, 100];

  @override
  Widget build(BuildContext context) {
    final name = value.companionName;
    final muted = TextStyle(fontSize: 12, color: context.palette.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: value.keepRunning,
          onChanged: (on) => onChanged(value.copyWith(keepRunning: on)),
          title: const Text('Close to the system tray'),
          subtitle: Text(
            'Closing the window leaves VoxCordis in the system tray, so '
            '$name\'s reminders and tasks still happen. Click the tray icon '
            'to come back, or choose Quit there or at the bottom of this '
            'page. Where the desktop has no tray (plain GNOME), the window '
            'goes to the taskbar instead.',
            style: muted,
          ),
        ),
        if (!Platform.isMacOS)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: value.startWithComputer,
            onChanged: (on) => onChanged(value.copyWith(startWithComputer: on)),
            title: const Text('Start with my computer'),
            subtitle: Text(
              value.keepRunning
                  ? 'Starts in the system tray when you log in.'
                  : 'Starts when you log in.',
              style: muted,
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                'Most tasks $name may run a day',
                style: TextStyle(color: context.palette.text),
              ),
            ),
            GlassSelect<int>(
              minWidth: _Poke.pickerWidth,
              value: _limits.contains(value.automationRunsPerDay)
                  ? value.automationRunsPerDay
                  : 24,
              options: [for (final n in _limits) GlassOption(n, '$n')],
              onChanged: (n) =>
                  onChanged(value.copyWith(automationRunsPerDay: n)),
            ),
            const SizedBox(width: 8),
            const InfoIcon(
              message:
                  'Each task run is a reply from the brain. With a '
                  'server-hosted brain every run costs a little, so this '
                  'caps a mistake like a task set to run every 15 minutes.',
            ),
          ],
        ),
      ],
    );
  }
}

/// How long a quiet spell lasts before the companion does something on
/// its own.
class _Poke extends StatelessWidget {
  const _Poke({required this.value, required this.onChanged});

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  static const _hours = [0, 1, 2, 3, 6, 12];

  /// The pickers at the end of the rows here and in [_Background], one width
  /// so they line up.
  static const pickerWidth = 150.0;

  Widget _dropdown(
    BuildContext context,
    int value,
    List<int> options,
    String Function(int) label,
    ValueChanged<int> onPicked, {
    double? minWidth,
  }) => GlassSelect<int>(
    value: value,
    minWidth: minWidth,
    options: [for (final o in options) GlassOption(o, label(o))],
    onChanged: onPicked,
  );

  static String _clock(int h) => '${h.toString().padLeft(2, '0')}:00';

  @override
  Widget build(BuildContext context) {
    final name = value.companionName;
    final on = value.pokeAfterHours > 0;
    final text = TextStyle(color: context.palette.text);
    final muted = TextStyle(fontSize: 12, color: context.palette.textMuted);
    final allDay = [for (var h = 0; h < 24; h++) h];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Apart from the picker above it, so the two don't touch.
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text('When it\'s been quiet, $name pokes', style: text),
            ),
            _dropdown(
              context,
              _hours.contains(value.pokeAfterHours) ? value.pokeAfterHours : 3,
              _hours,
              (h) => switch (h) {
                0 => 'Never',
                1 => 'After 1 hour',
                _ => 'After $h hours',
              },
              (h) => onChanged(value.copyWith(pokeAfterHours: h)),
              minWidth: pickerWidth,
            ),
            const SizedBox(width: 8),
            InfoIcon(
              message:
                  'After this long with nobody writing, $name does '
                  'something unasked: writes you a message, potters about '
                  'with the notes, or falls into a web rabbit hole when '
                  'Internet is on. Each poke is a reply from the brain.',
            ),
          ],
        ),
        if (on) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: value.pokeRepeat,
            onChanged: (v) => onChanged(value.copyWith(pokeRepeat: v)),
            title: const Text('Keep poking while I\'m away'),
            subtitle: Text(
              value.pokeRepeat
                  ? 'Again after every quiet spell, until you write.'
                  : 'Once, then $name waits for you to write.',
              style: muted,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Text('No pokes from', style: text)),
              _dropdown(
                context,
                value.pokeQuietFrom.clamp(0, 23),
                allDay,
                _clock,
                (h) => onChanged(value.copyWith(pokeQuietFrom: h)),
              ),
              const SizedBox(width: 8),
              Text('until', style: text),
              const SizedBox(width: 8),
              _dropdown(
                context,
                value.pokeQuietUntil.clamp(0, 23),
                allDay,
                _clock,
                (h) => onChanged(value.copyWith(pokeQuietUntil: h)),
              ),
              const SizedBox(width: 8),
              const InfoIcon(
                message:
                    'Quiet hours, like the night. Pick the same time twice '
                    'to allow pokes at any hour.',
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 2),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// The switch that lets the companion run commands and open things, the
/// requests allowed always, and the log. Changes apply at once.
class _SystemAccess extends StatelessWidget {
  const _SystemAccess();

  Future<void> _toggle(BuildContext context, bool on) async {
    final store = AppScope.of(context).settings;
    final name = store.value.companionName;
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orangeAccent,
          ),
          title: Text('Let $name use this computer?'),
          content: SizedBox(
            width: 420,
            child: Text(
              '$name will be able to ask to run commands and to open web '
              'addresses, files, folders and programs, as you, with '
              'everything you can reach.\n\n'
              'Each request shows you exactly what will happen and waits '
              'for your OK, unless you chose "Always allow" for that exact '
              'one. A model can misunderstand, or be talked into something '
              'by text it reads, so only allow what you understand.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Turn on'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await store.update(store.value.copyWith(systemAccess: on));
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final store = services.settings;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final s = store.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Section('System access'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.systemAccess,
              onChanged: (on) => _toggle(context, on),
              title: Text('Let ${s.companionName} use this computer'),
              subtitle: Text(
                'Run commands and open web addresses, files and programs. '
                'You approve every request.',
                style: TextStyle(
                  fontSize: 12,
                  color: context.palette.textMuted,
                ),
              ),
            ),
            const _Section('Always allowed'),
            if (s.allowedSystemActions.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Nothing yet. Choose "Always allow this" on a request to '
                  'skip asking for that exact one next time.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textMuted,
                  ),
                ),
              )
            else
              for (final key in s.allowedSystemActions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    key,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  trailing: IconButton(
                    tooltip: 'Ask again next time',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => store.update(
                      store.value.copyWith(
                        allowedSystemActions: [
                          for (final k in store.value.allowedSystemActions)
                            if (k != key) k,
                        ],
                      ),
                    ),
                  ),
                ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final log = services.systemLog;
                  if (!await log.exists()) {
                    await log.parent.create(recursive: true);
                    await log.writeAsString('');
                  }
                  await launchUrl(Uri.file(log.path));
                },
                icon: const Icon(Icons.receipt_long_rounded),
                label: const Text('Open the log'),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Version, a manual check, and the result of the last check.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow();

  @override
  Widget build(BuildContext context) {
    final updater = AppScope.of(context).updates;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final info = updater.available;
        final status = switch (updater.status) {
          UpdateStatus.checking => 'Checking…',
          UpdateStatus.upToDate => 'You have the newest version.',
          UpdateStatus.failed => updater.error ?? '',
          _ when info != null => 'Version ${info.version} is available.',
          _ => '',
        };
        return Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('VoxCordis $appVersion'),
            if (info != null)
              FilledButton.icon(
                onPressed: () => showUpdateDialog(context),
                icon: const Icon(Icons.arrow_circle_up_rounded),
                label: Text('Update to ${info.version}'),
              )
            else
              OutlinedButton.icon(
                onPressed: updater.status == UpdateStatus.checking
                    ? null
                    : updater.check,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Check for updates'),
              ),
            TextButton.icon(
              onPressed: () async {
                final entry = await WhatsNew.latest();
                if (entry == null || !context.mounted) return;
                await showWhatsNew(context, [entry], host: const _NoHost());
              },
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('What\'s new'),
            ),
            if (status.isNotEmpty)
              Text(
                status,
                style: TextStyle(
                  color: updater.status == UpdateStatus.failed
                      ? Colors.redAccent
                      : context.palette.textMuted,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Every look in one list: the standard ones change the accent and the
/// glows, the special colorways below them tint the window and panels too.
/// Applies at once.
class _Colorways extends StatelessWidget {
  const _Colorways({required this.onPicked});

  final ValueChanged<Look> onPicked;

  /// The look in use, or null when the colours were set some other way
  /// (by hand or by the companion).
  static Look? current(AppSettings s) {
    if (s.colorway != null) return Look.byId(s.colorway);
    for (final l in Look.all) {
      if (s.accentColor != l.accent) continue;
      if (listEquals(s.backgroundColors, l.colors)) return l;
      if (l == Look.all.first && s.backgroundColors.isEmpty) return l;
    }
    return null;
  }

  GlassOption<String> _item(BuildContext context, Look look) =>
      GlassOption(look.id, look.label, leading: _Orb.of(context, look));

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final s = store.value;
        final now = current(s);
        return Row(
          children: [
            Text(
              'Colorway',
              style: TextStyle(color: context.palette.textMuted),
            ),
            const SizedBox(width: 12),
            GlassSelect<String>(
              value: now?.id ?? '',
              options: [
                if (now == null)
                  GlassOption(
                    '',
                    'Custom',
                    leading: _Orb(
                      base: context.palette.background,
                      glows: s.backgroundColors.isEmpty
                          ? [s.accentColor]
                          : s.backgroundColors,
                    ),
                  ),
                for (final look in [...Look.all, ...Look.special])
                  _item(context, look),
              ],
              onChanged: (id) {
                final look = Look.byId(id);
                if (look == null) return;
                store.update(
                  s.copyWith(
                    accentColor: look.accent,
                    backgroundColors: look.colors,
                    backgroundLayout: look.layout,
                    colorway: look.isSpecial ? look.id : '',
                  ),
                );
                onPicked(look);
              },
            ),
            const SizedBox(width: 8),
            const InfoIcon(
              message:
                  'Each orb shows its colours on the window. Most change the '
                  'accent and the soft glows; Haru, Vibecoder\'s and Sakura '
                  'recolour the window and panels too.',
            ),
          ],
        );
      },
    );
  }
}

/// A small glossy orb that shows a look as it will be: its glows on the
/// window colour of the current theme, lit from the top left.
class _Orb extends StatelessWidget {
  const _Orb({required this.base, required this.glows});

  /// [look] in the current theme. While the theme fades between dark and
  /// light the orb fades with it, rather than switching all at once.
  factory _Orb.of(BuildContext context, Look look) {
    final t = context.palette.lightness;
    final dark = look.colorsIn(light: false);
    final light = look.colorsIn(light: true);
    return _Orb(
      base: Color.lerp(
        _baseOf(look, light: false),
        _baseOf(look, light: true),
        t,
      )!,
      glows: [
        for (var i = 0; i < math.max(dark.length, light.length); i++)
          Color.lerp(
            Color(dark[math.min(i, dark.length - 1)]),
            Color(light[math.min(i, light.length - 1)]),
            t,
          )!.toARGB32(),
      ],
    );
  }

  final Color base;
  final List<int> glows;

  static Color _baseOf(Look look, {required bool light}) {
    final own = light ? look.lightBase : look.base;
    if (own != null) return Color(own);
    return (light ? AppPalette.light : AppPalette.dark).background;
  }

  /// Where the glows sit, like the soft lights behind the panels.
  static const _spots = [
    Alignment(-0.7, -0.7),
    Alignment(0.75, -0.1),
    Alignment(-0.15, 0.8),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: base,
        border: Border.all(color: context.palette.glassBorder),
        boxShadow: [
          BoxShadow(
            color: (glows.isEmpty ? base : Color(glows.first)).withValues(
              alpha: 0.4,
            ),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      // A soft shine, so it reads as a sphere rather than a flat dot.
      foregroundDecoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 0.55,
          colors: [Color(0x80FFFFFF), Color(0x00FFFFFF)],
        ),
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < glows.length && i < _spots.length; i++)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: _spots[i],
                    radius: 0.6,
                    colors: [
                      Color(glows[i]).withValues(alpha: 0.95),
                      Color(glows[i]).withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A picture of the human's (or one the companion picked) in the main
/// panel, darkened so the chat stays readable.
class _BackgroundPicture extends StatelessWidget {
  const _BackgroundPicture();

  Future<void> _choose(BuildContext context) async {
    final services = AppScope.of(context);
    final folder = services.settings.value.companionFolder;
    if (folder == null) return;
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Picture',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (picked == null) return;
    final file = File(picked.path);
    if (!await Pictures.isImage(file)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That is not a PNG, JPEG or WebP.')),
        );
      }
      return;
    }
    await Pictures.setBackground(folder, file);
    services.backgroundChanged();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        services.settings,
        services.backgroundRevision,
      ]),
      builder: (context, _) {
        final s = services.settings.value;
        final folder = s.companionFolder;
        final has = folder != null && Pictures.backgroundIn(folder) != null;
        return Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Background picture',
              style: TextStyle(color: context.palette.textMuted),
            ),
            OutlinedButton.icon(
              onPressed: folder == null ? null : () => _choose(context),
              icon: const Icon(Icons.wallpaper_rounded),
              label: Text(has ? 'Change…' : 'Choose…'),
            ),
            if (has) ...[
              TextButton(
                onPressed: () async {
                  await Pictures.clearBackground(folder);
                  services.backgroundChanged();
                },
                child: const Text('Remove'),
              ),
              Text(
                'Darkness',
                style: TextStyle(color: context.palette.textMuted),
              ),
              SizedBox(
                width: 180,
                child: Slider(
                  value: s.backgroundDim,
                  min: 0.3,
                  max: 0.9,
                  onChanged: (v) => services.settings.update(
                    services.settings.value.copyWith(backgroundDim: v),
                  ),
                ),
              ),
            ],
            InfoIcon(
              message:
                  'Shown darkened in the big panel on the right, behind the '
                  'chat and the other tabs; the rest keeps the colorway. '
                  "Each companion has its own; ${s.companionName} "
                  'can pick one from its folder too.',
            ),
          ],
        );
      },
    );
  }
}

/// What VoxCordis is, its version and updates, and its licence.
class _About extends StatelessWidget {
  const _About();

  static const _gpl = 'https://www.gnu.org/licenses/gpl-3.0.html';

  /// The community server, for news, help and sharing companions.
  static const discord = 'https://discord.gg/hJCzp7tVaT';

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);
    // Test builds point at the private repository; only the public one has
    // source anyone can open.
    final source = updateRepo.endsWith('PR')
        ? null
        : 'https://github.com/$updateRepo';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        Row(
          children: [
            Image.asset(AppTheme.heartMark, height: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'VOX ',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        TextSpan(
                          text: 'CORDIS',
                          style: TextStyle(fontWeight: FontWeight.w300),
                        ),
                      ],
                    ),
                    style: TextStyle(fontSize: 20, letterSpacing: 3),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'A companion that lives on your computer. Chats, '
                    'memories and files stay here unless you choose a '
                    'server-hosted brain.',
                    style: muted,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: () => launchUrl(Uri.parse(discord)),
          icon: const Icon(Icons.forum_outlined),
          label: const Text('Join the VoxCordis Discord'),
        ),
        const _Section('Version'),
        const SizedBox(height: 8),
        const _UpdateRow(),
        const _Section('Licence'),
        const SizedBox(height: 6),
        Text(
          'VoxCordis is free software under the GNU General Public '
          'License, version 3. You may use, study, share and change it; '
          'anything you share built from it keeps the same licence. It '
          'comes with no warranty.\n'
          'Copyright © 2026 Nucume.',
          style: muted,
        ),
        const SizedBox(height: 6),
        Text(
          'Local brains run on llama.cpp (MIT licence). The models you '
          'download keep their own licences, shown where you pick them.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(_gpl)),
              icon: const Icon(Icons.gavel_rounded),
              label: const Text('Read the GPL-3.0'),
            ),
            if (source != null)
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(source)),
                icon: const Icon(Icons.code_rounded),
                label: const Text('Source code'),
              ),
            TextButton.icon(
              onPressed: () => _openLicenses(context),
              icon: const Icon(Icons.library_books_outlined),
              label: const Text('Open-source parts'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Flutter's licence page on a solid background. The app's pages are
/// see-through and the glows sit under the first page only, so a full page
/// pushed on top would leave the whole window transparent.
void _openLicenses(BuildContext context) {
  final theme = Theme.of(context);
  final solid = context.palette.background.withValues(alpha: 1);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Theme(
        data: theme.copyWith(
          scaffoldBackgroundColor: solid,
          canvasColor: solid,
          appBarTheme: theme.appBarTheme.copyWith(backgroundColor: solid),
        ),
        child: const LicensePage(
          applicationName: 'VoxCordis',
          applicationVersion: appVersion,
          applicationLegalese: 'Copyright © 2026 Nucume · GPL-3.0',
        ),
      ),
    ),
  );
}

/// Already in Settings, so an action there just closes the notes.
enum _Leave { save, discard, cancel }

class _NoHost implements WhatsNewHost {
  const _NoHost();

  @override
  void openSettings({int tab = 0}) {}
}

/// The companion's own section: a plain note on how to change who they are,
/// their folder, and the files that shape them.
class _CompanionFiles extends StatelessWidget {
  const _CompanionFiles({
    required this.name,
    required this.folder,
    required this.onChangeFolder,
    required this.onOpenFile,
  });

  final String name;
  final String? folder;
  final VoidCallback onChangeFolder;
  final Future<void> Function(File file) onOpenFile;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final folder = this.folder;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.tile,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.glassBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 18,
                  color: palette.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'To change $name\'s name, pronouns, traits or portrait, '
                    'ask in the chat.',
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.35,
                      color: palette.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.folder_rounded, size: 18, color: palette.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Tooltip(
                    message: folder ?? '',
                    child: Text(
                      folder ?? 'No folder yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: palette.textMuted),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (folder != null)
                  TextButton(
                    onPressed: () =>
                        CompanionFolder(folder).openInFileManager(),
                    child: const Text('Open'),
                  ),
                TextButton(
                  onPressed: onChangeFolder,
                  child: Text(folder == null ? 'Choose' : 'Change'),
                ),
              ],
            ),
            if (folder != null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (file, label, icon) in [
                    (
                      CoreRules.fileIn(folder),
                      'House rules',
                      Icons.description_outlined,
                    ),
                    (
                      DeskFiles.fileIn(folder, DeskFiles.personality),
                      'Personality',
                      Icons.face_rounded,
                    ),
                    (
                      DeskFiles.fileIn(folder, DeskFiles.lessons),
                      'Lessons',
                      Icons.school_outlined,
                    ),
                    (
                      DeskFiles.fileIn(folder, DeskFiles.privacy),
                      'Privacy rules',
                      Icons.lock_outline_rounded,
                    ),
                  ])
                    FilledButton.tonalIcon(
                      onPressed: () => onOpenFile(file),
                      icon: Icon(icon, size: 18),
                      label: Text(label),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
