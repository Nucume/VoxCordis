import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../app_scope.dart';
import '../../data/core_rules.dart';
import '../../data/desk/desk_files.dart';
import '../../data/desk/pictures.dart';
import '../../data/settings.dart';
import '../../services/folder_service.dart';
import '../../services/import/import_temp.dart';
import '../../services/import/imported_character.dart';
import '../../services/import/import_writer.dart';
import '../../theme/app_theme.dart';
import '../../shell/portrait.dart';
import '../settings/model_picker.dart';
import 'character_pickers.dart';
import 'import_step.dart';

enum _Step {
  welcome('', Size(560, 440)),
  import_('Import', Size(640, 500)),
  character('Character', Size(640, 400)),
  personality('Personality', Size(1000, 760)),
  story('Story', Size(1000, 780)),
  you('You', Size(640, 380)),
  home('Home', Size(640, 330)),
  brain('Brain', Size(860, 780));

  const _Step(this.label, this.size);

  final String label;

  /// The box grows and shrinks to fit each step.
  final Size size;
}

/// First run: a welcome, then the character, its personality, who the user
/// is, a home folder and its brain, in one glass box that resizes for each step.
///
/// "Import a character" first reads one from another app (see
/// import_step.dart), fills in the same steps from it, and adds a Story step
/// to review the text before it becomes personality.md.
///
/// With [addingAnother] it sets up one more companion beside the current
/// one: only the companion's own steps, since the human, the VoxCordis
/// folder and the brain are shared.
class SetupWizard extends StatefulWidget {
  const SetupWizard({super.key, this.addingAnother = false});

  final bool addingAnother;

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  _Step _step = _Step.welcome;
  late AppSettings _draft;

  /// The settings setup started with, to go back to when an import is
  /// dropped.
  late AppSettings _initial;
  final _name = TextEditingController();

  /// Set while the user goes the import way, and once a file is read.
  bool _importing = false;
  ImportedCharacter? _imported;
  final _story = TextEditingController();
  final _looks = {
    for (final k in DeskFiles.looksKeys) k: TextEditingController(),
  };
  final _userName = TextEditingController();
  // One per step: during the cross-fade two steps are on screen at once.
  final _scrolls = {for (final s in _Step.values) s: ScrollController()};

  /// The VoxCordis folder: the companion's folder and `models` go in it.
  String _root = VoxCordisFolder.defaultRoot;

  /// A models folder from an earlier install, kept where it is.
  String? _keptModels;
  bool _loaded = false;
  bool _saving = false;

  /// The steps after the welcome, in order, for the way the user chose.
  List<_Step> get _flow => [
    if (_importing) _Step.import_,
    _Step.character,
    _Step.personality,
    if (_imported != null) _Step.story,
    if (!_adding) ...[_Step.you, _Step.home, _Step.brain],
  ];

  bool get _adding => widget.addingAnother;

  /// The steps shown as dots: choosing the file is not one of them.
  List<_Step> get _steps => [
    for (final s in _flow)
      if (s != _Step.import_) s,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final current = AppScope.of(context).settings.value;
    // Another companion starts blank, and moves in beside the others.
    _draft = _initial = _adding
        ? current.copyWith(
            companionName: const AppSettings().companionName,
            pronouns: const AppSettings().pronouns,
            traits: const AppSettings().traits,
            accentColor: const AppSettings().accentColor,
            clearPortrait: true,
            clearBackground: true,
          )
        : current;
    if (_adding && current.companionFolder != null) {
      _root = p.dirname(current.companionFolder!);
    }
    _name.text = _draft.companionName == 'Companion'
        ? ''
        : _draft.companionName;
    _userName.text = _draft.userName;
    _keptModels = _draft.modelsFolder;
  }

  @override
  void dispose() {
    _name.dispose();
    _userName.dispose();
    _story.dispose();
    for (final c in _looks.values) {
      c.dispose();
    }
    for (final c in _scrolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  String get _nameValue =>
      _name.text.trim().isEmpty ? 'Companion' : _name.text.trim();

  /// `~/VoxCordis/<Name>` unless the user puts VoxCordis somewhere else.
  String get _folder => VoxCordisFolder.companion(_root, _nameValue);

  String get _modelsFolder => _keptModels ?? VoxCordisFolder.models(_root);

  /// The companion already living in [_folder], when adding another.
  String? get _folderTakenBy {
    if (!_adding) return null;
    for (final c in AppScope.of(context).settings.value.companions) {
      if (p.equals(c.folder, _folder)) return c.name;
    }
    return null;
  }

  bool get _canContinue => switch (_step) {
    _Step.character => _name.text.trim().isNotEmpty && _folderTakenBy == null,
    _Step.story => _story.text.length <= ImportReview.maxBody,
    _Step.import_ => false,
    _Step.brain => _draft.copyWith(companionFolder: _folder).isSetUp,
    _ => true,
  };

  void _go(_Step to) => setState(() => _step = to);

  void _next() => _go(_flow[_flow.indexOf(_step) + 1]);

  void _back() {
    final i = _flow.indexOf(_step);
    _go(i <= 0 ? _Step.welcome : _flow[i - 1]);
  }

  /// From the welcome: [import] picks the way, and a character imported
  /// earlier is dropped when the user starts over the other way.
  void _start({required bool import}) {
    if (!import && _imported != null) {
      _imported = null;
      _draft = _initial;
      _name.text = _initial.companionName == 'Companion'
          ? ''
          : _initial.companionName;
      _userName.text = _initial.userName;
    }
    _importing = import;
    _go(import ? _Step.import_ : _Step.character);
  }

  /// Fills the steps from [c] and moves on to the character, where the user
  /// sees and can change all of it.
  void _onImported(ImportedCharacter c) {
    setState(() {
      _imported = c;
      _draft = _initial.copyWith(
        pronouns: c.pronouns ?? _initial.pronouns,
        traits: c.traits.isEmpty ? null : c.traits,
        portraitPath: c.portrait?.path,
        clearPortrait: c.portrait == null,
      );
      _name.text = c.name;
      if (_userName.text.trim().isEmpty && c.userName != null) {
        _userName.text = c.userName!;
      }
      _story.text = c.body;
      for (final k in DeskFiles.looksKeys) {
        _looks[k]!.text = c.looks[k] ?? '';
      }
      _step = _Step.character;
    });
  }

  Future<void> _pickPortrait() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp']),
      ],
    );
    if (file == null) return;
    setState(() => _draft = _draft.copyWith(portraitPath: file.path));
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Put VoxCordis here',
    );
    if (path == null) return;
    setState(() => _root = VoxCordisFolder.inside(path));
  }

  /// Back to the companion the human came from.
  void _cancelAdding() => AppScope.of(context).addingCompanion.value = false;

  /// Another companion: its files and database first, then the window
  /// switches to it. The current companion is kept as it is.
  Future<void> _finishAdding() async {
    setState(() => _saving = true);
    final services = AppScope.of(context);
    final id = const Uuid().v4();
    final s = _draft.copyWith(
      companionName: _nameValue,
      companionFolder: _folder,
    );
    final db = await services.openCompanionDb(id);
    await CompanionFolder(_folder).ensureExists();
    final imported = _imported;
    if (imported != null) {
      await ImportWriter.write(
        imported,
        s,
        body: _story.text,
        looks: {for (final e in _looks.entries) e.key: e.value.text.trim()},
        db: db,
      );
    }
    await CoreRules.load(s);
    await DeskFiles.ensure(s);
    final portrait = await _settlePortrait(s.portraitPath);
    final next = services.settings.value.switchedTo(
      CompanionProfile(
        id: id,
        name: s.companionName,
        folder: _folder,
        pronouns: s.pronouns,
        traits: s.traits,
        portraitPath: portrait,
        accentColor: s.accentColor,
      ),
    );
    await services.switchCompanion(next, nextDb: db);
    services.addingCompanion.value = false;
  }

  /// The portrait chosen in setup is the companion's avatar in its folder
  /// by now. A picture that came with the import pointed at a temporary
  /// copy; point at the avatar instead and delete that copy.
  Future<String?> _settlePortrait(String? path) async {
    final avatar = Pictures.avatarIn(_folder);
    if (avatar == null || !ImportTemp.holds(path)) return path;
    await ImportTemp.remove(path);
    return avatar.path;
  }

  Future<void> _finish() async {
    if (_adding) {
      try {
        return await _finishAdding();
      } catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add $_nameValue: $e')),
        );
        return;
      }
    }
    var next = _draft.copyWith(
      companionName: _nameValue,
      userName: _userName.text.trim(),
      companionFolder: _folder,
      modelsFolder: _modelsFolder,
    );
    if (!await confirmModelFits(context, next)) return;
    if (!mounted) return;
    setState(() => _saving = true);
    final services = AppScope.of(context);
    await CompanionFolder(_folder).ensureExists();
    final imported = _imported;
    if (imported != null) {
      final brought = await ImportWriter.write(
        imported,
        next,
        body: _story.text,
        looks: {for (final e in _looks.entries) e.key: e.value.text.trim()},
        db: services.db,
      );
      if (brought.memories > 0) services.memoryChanged();
    }
    await CoreRules.load(next);
    await DeskFiles.ensure(next);
    next = next.copyWith(
      portraitPath: await _settlePortrait(next.portraitPath),
    );
    await services.settings.update(next);
    services.runtime.ensureReady(next).ignore();
    services.rewriteIfAsked().ignore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Never bigger than the window, minus a margin.
          // The picture offer on the character step needs a little room.
          final size = _step == _Step.character && _pictureOffer != null
              ? Size(_step.size.width, _step.size.height + 70)
              : _step.size;
          final width = size.width.clamp(0.0, constraints.maxWidth - 48);
          // Adding another has one more button on the welcome.
          final extra = _adding && _step == _Step.welcome ? 50.0 : 0.0;
          final height = (size.height + extra).clamp(
            0.0,
            constraints.maxHeight - 48,
          );
          return Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeInOutCubic,
              width: width,
              height: height,
              child: GlassPanel(
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: const Interval(0.35, 1),
                    transitionBuilder: (child, a) =>
                        FadeTransition(opacity: a, child: child),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _step == _Step.welcome ? _welcome() : _stepFrame(),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _welcome() => Padding(
    padding: const EdgeInsets.all(36),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1),
          duration: const Duration(milliseconds: 900),
          curve: Curves.elasticOut,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Image.asset(AppTheme.heartMark, height: 110),
        ),
        const SizedBox(height: 24),
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
          style: TextStyle(fontSize: 30, letterSpacing: 5),
        ),
        const SizedBox(height: 12),
        Text(
          _adding
              ? 'Someone new joins ${AppScope.of(context).settings.value.companionName}.\n'
                    'Let\'s bring them to life.'
              : 'A companion that lives on your computer.\n'
                    'Let\'s bring yours to life.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.textMuted, height: 1.5),
        ),
        const SizedBox(height: 30),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: () => _start(import: false),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('Begin'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 16,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _start(import: true),
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Import a character'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
        if (_adding) ...[
          const SizedBox(height: 14),
          TextButton(
            onPressed: _cancelAdding,
            child: Text(
              'Back to ${AppScope.of(context).settings.value.companionName}',
            ),
          ),
        ],
      ],
    ),
  );

  Widget _stepFrame() {
    final steps = _steps;
    final index = steps.indexOf(_step);
    final last = index == steps.length - 1;
    final choosing = _step == _Step.import_;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 26, 32, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset(AppTheme.heartMark, height: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _title(),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (!choosing)
                for (var i = 0; i < steps.length; i++)
                  _StepDot(
                    label: steps[i].label,
                    active: i == index,
                    done: i < index,
                  ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Scrollbar(
              controller: _scrolls[_step],
              // Always shown when the content is longer than the box, so it
              // is clear there is more below.
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scrolls[_step],
                padding: const EdgeInsets.only(right: 16),
                child: _body(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(onPressed: _back, child: const Text('Back')),
              const Spacer(),
              if (!choosing)
                FilledButton.icon(
                  onPressed: !_canContinue || _saving
                      ? null
                      : last
                      ? _finish
                      : _next,
                  icon: Icon(
                    last ? Icons.favorite_rounded : Icons.arrow_forward_rounded,
                  ),
                  label: Text(last ? 'Meet $_nameValue' : 'Continue'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _title() => switch (_step) {
    _Step.import_ => 'Import a character',
    _Step.character => 'Who is your companion?',
    _Step.story => 'Read $_nameValue\'s story',
    _Step.personality => 'What is $_nameValue like?',
    _Step.you => 'And who are you?',
    _Step.home => 'A home for $_nameValue',
    _ => 'Choose $_nameValue\'s brain',
  };

  /// The imported character's linked picture, while no portrait is set.
  Uri? get _pictureOffer =>
      _draft.portraitPath == null ? _imported?.avatarUrl : null;

  /// "she" for she/her, "they" for they/them; falls back to the name.
  String _pronounSubject() {
    final first = _draft.pronouns.split('/').first.trim();
    return first.isEmpty || first == 'any' ? _nameValue : first;
  }

  Widget _body() => switch (_step) {
    _Step.import_ => ImportSources(onImported: _onImported),
    _Step.story => ImportReview(
      character: _imported!,
      name: _nameValue,
      body: _story,
      looks: _looks,
    ),
    _Step.character => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'After setup, name, pronouns and picture are your companion\'s to '
          'change. You can always ask.',
          style: TextStyle(color: context.palette.textMuted),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Tooltip(
                  message: _draft.portraitPath == null
                      ? 'Choose a picture'
                      : 'Change the picture',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _pickPortrait,
                      child: Portrait(
                        path: _draft.portraitPath,
                        size: 140,
                        placeholder: Icon(
                          Icons.add_a_photo_outlined,
                          size: 30,
                          color: context.palette.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_draft.portraitPath == null)
                  Text(
                    'Picture (optional)',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.textMuted,
                    ),
                  )
                else
                  TextButton(
                    onPressed: () => setState(
                      () => _draft = _draft.copyWith(clearPortrait: true),
                    ),
                    child: const Text('Remove picture'),
                  ),
              ],
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _name,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (_canContinue) _next();
                    },
                    decoration: InputDecoration(
                      labelText: 'Name',
                      errorText: _folderTakenBy == null
                          ? null
                          : 'You already have a companion called '
                                '$_folderTakenBy',
                    ),
                  ),
                  const SizedBox(height: 16),
                  PronounPicker(
                    value: _draft.pronouns,
                    onChanged: (v) =>
                        setState(() => _draft = _draft.copyWith(pronouns: v)),
                  ),
                  const SizedBox(height: 14),
                  if (_pictureOffer case final url?)
                    PortraitDownload(
                      url: url,
                      onPortrait: (f) => setState(
                        () => _draft = _draft.copyWith(portraitPath: f.path),
                      ),
                    )
                  else
                    Text(
                      'No picture? Your companion can choose a look once it '
                      'knows who it is.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: context.palette.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
    _Step.personality => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'This shapes how ${_pronounSubject()} talks to you.',
          style: TextStyle(color: context.palette.textMuted, height: 1.4),
        ),
        const SizedBox(height: 14),
        TraitPicker(
          value: _draft.traits,
          max: _imported == null ? TraitPicker.defaultMax : DeskFiles.maxTraits,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(traits: v)),
        ),
      ],
    ),
    _Step.you => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'So $_nameValue knows how to talk to you. You can change this later.',
          style: TextStyle(color: context.palette.textMuted, height: 1.4),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _userName,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'What should $_nameValue call you?',
            hintText: 'Your name or a nickname',
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Your pronouns',
          style: TextStyle(fontSize: 12, color: context.palette.textMuted),
        ),
        const SizedBox(height: 8),
        PronounPicker(
          value: _draft.userPronouns,
          optional: true,
          onChanged: (v) =>
              setState(() => _draft = _draft.copyWith(userPronouns: v)),
        ),
      ],
    ),
    _Step.home => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$_nameValue keeps pictures and files in a real folder you can open '
          'any time. ${_nameValue.split(' ').first} can read and write there, '
          'and nowhere else. Downloaded models go next to it.',
          style: TextStyle(color: context.palette.textMuted, height: 1.4),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.palette.tile,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayPath(_folder)),
                    const SizedBox(height: 2),
                    Text(
                      'Models: ${displayPath(_modelsFolder)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: _pickFolder, child: const Text('Change')),
            ],
          ),
        ),
      ],
    ),
    _ => ModelPicker(
      value: _draft.copyWith(modelsFolder: _modelsFolder),
      onChanged: (v) => setState(() => _draft = v),
      showModelsFolder: false,
    ),
  };
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.label,
    required this.active,
    required this.done,
  });

  final String label;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: active ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: active || done ? accent : context.palette.glassBorder,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          // Only the current step is named, so four steps fit beside the
          // title.
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            child: active
                ? Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.text,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
