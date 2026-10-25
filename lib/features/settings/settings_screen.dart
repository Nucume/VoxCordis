import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/core_rules.dart';
import '../../data/desk/desk_files.dart';
import '../../data/settings.dart';
import '../../services/folder_service.dart';
import '../../theme/app_theme.dart';
import '../../services/updater.dart';
import '../setup/character_pickers.dart';
import '../update/update_dialog.dart';
import 'model_picker.dart';

/// Minimal v1 Settings: General, Brain (the model) and Images. Other tabs arrive with the systems
/// they control.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _draft;
  late final _userName = TextEditingController();
  late final _invoke = TextEditingController();
  bool _loaded = false;

  static const _accents = [
    0xFFB18CFF,
    0xFFFF7AB6,
    0xFF6FA8FF,
    0xFF5EE6C0,
    0xFFFFB86B,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _draft = AppScope.of(context).settings.value;
    _userName.text = _draft.userName;
    _invoke.text = _draft.invokeUrl;
  }

  @override
  void dispose() {
    for (final c in [_userName, _invoke]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
    if (path == null) return;
    setState(() => _draft = _draft.copyWith(companionFolder: path));
  }

  Future<void> _save() async {
    final current = AppScope.of(context).settings.value;
    final next = _draft.copyWith(
      // After setup name, pronouns, traits and portrait are the companion's
      // own; keep what it last saved, not this page's copy.
      companionName: current.companionName,
      traits: current.traits,
      pronouns: current.pronouns,
      portraitPath: current.portraitPath,
      // System access applies at once on its page, and "Always allow" in
      // the chat adds to the list while this page is open.
      systemAccess: current.systemAccess,
      allowedSystemActions: current.allowedSystemActions,
      // Switching and adding companions happen outside this page.
      otherCompanions: current.otherCompanions,
      toldAboutMoreCompanions: current.toldAboutMoreCompanions,
      // The look applies at once, and the companion may restyle it.
      accentColor: current.accentColor,
      backgroundColors: current.backgroundColors,
      backgroundLayout: current.backgroundLayout,
      themeChoice: current.themeChoice,
      clearBackground:
          current.backgroundColors.isEmpty && current.backgroundLayout == null,
      userName: _userName.text.trim(),
      invokeUrl: _invoke.text.trim(),
    );
    if (!await confirmModelFits(context, next)) return;
    final folder = next.companionFolder;
    if (folder != null) {
      await CompanionFolder(folder).ensureExists();
      await CoreRules.load(next); // writes core.md the first time
      await DeskFiles.ensure(next);
    }
    if (!mounted) return;
    final services = AppScope.of(context);
    await services.settings.update(next);
    // Load the (possibly new) model in the background so chat is ready.
    services.runtime.ensureReady(next).ignore();
    if (!mounted) return;
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
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
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
                Tab(text: 'Images'),
                Tab(text: 'Brain'),
                Tab(text: 'Computer'),
                Tab(text: 'About'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _page(_general()),
                _page([
                  _field(
                    _invoke,
                    'InvokeAI URL',
                    hint: 'http://localhost:9090',
                  ),
                ]),
                _page([
                  const SizedBox(height: 14),
                  ModelPicker(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                  const SizedBox(height: 28),
                  BrainAdvanced(
                    value: _draft,
                    onChanged: (v) => setState(() => _draft = v),
                  ),
                ]),
                _page(const [_SystemAccess()]),
                _page(const [SizedBox(height: 18), _UpdateRow()]),
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

  List<Widget> _general() {
    final folder = _draft.companionFolder;
    final name = _draft.companionName;
    return [
      const _Section('Appearance'),
      const SizedBox(height: 8),
      Row(
        children: [
          Text('Accent', style: TextStyle(color: context.palette.textMuted)),
          const SizedBox(width: 12),
          for (final c in _accents)
            GestureDetector(
              // Applies (and saves) at once, so the change is visible.
              onTap: () {
                setState(() => _draft = _draft.copyWith(accentColor: c));
                final store = AppScope.of(context).settings;
                store.update(store.value.copyWith(accentColor: c));
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(right: 8),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _draft.accentColor == c
                        ? context.palette.text
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            ),
          const Spacer(),
          // The companion may have restyled the background; this undoes it.
          if (_draft.backgroundColors.isNotEmpty ||
              _draft.backgroundLayout != null)
            TextButton(
              onPressed: () {
                setState(() => _draft = _draft.copyWith(clearBackground: true));
                final store = AppScope.of(context).settings;
                store.update(store.value.copyWith(clearBackground: true));
              },
              child: Text("Undo $name's background"),
            ),
        ],
      ),
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
