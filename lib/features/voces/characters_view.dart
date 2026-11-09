import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/voces/describer.dart';
import '../../theme/app_theme.dart';
import 'voces_editor.dart';
import 'voces_home.dart';
import 'voces_picture.dart';
import 'voces_widgets.dart';

/// The Characters tab: everyone in the library, filtered by world or by
/// "played by you", and the sheet of the one picked.
///
/// Who plays a character is never stored here: it is picked per story, and
/// in that story the AI never voices the human's character.
class CharactersView extends StatefulWidget {
  const CharactersView({
    super.key,
    required this.data,
    required this.selected,
    required this.onSelect,
  });

  final VocesData data;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  State<CharactersView> createState() => _CharactersViewState();
}

/// "All", a world's id, or [_played].
const _played = '\u0000played';

class _CharactersViewState extends State<CharactersView> {
  String? _filter;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final palette = context.palette;
    final playedIds = {for (final s in data.stories) s.playerId};
    final filter = _filter;
    final shown = [
      for (final c in data.characters)
        if (filter == null ||
            (filter == _played && playedIds.contains(c.id)) ||
            (data.world(filter)?.castIds.contains(c.id) ?? false))
          c,
    ];
    final picked =
        (widget.selected == null ? null : data.character(widget.selected!)) ??
        shown.firstOrNull;
    return LayoutBuilder(
      builder: (context, box) => Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              // Narrower in a small window, so the sheet keeps its room.
              width: (box.maxWidth * 0.38).clamp(200.0, 300.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Characters',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: palette.text,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'New character',
                        onPressed: () async {
                          final made = await editCharacter(context, data, null);
                          if (made != null) widget.onSelect(made.id);
                        },
                        icon: const Icon(Icons.person_add_alt_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      VocesPill(
                        'All',
                        on: filter == null,
                        onTap: () => setState(() => _filter = null),
                      ),
                      for (final w in data.worlds)
                        VocesPill(
                          w.name,
                          on: filter == w.id,
                          onTap: () => setState(() => _filter = w.id),
                        ),
                      if (playedIds.isNotEmpty)
                        VocesPill(
                          'Played by you',
                          on: filter == _played,
                          onTap: () => setState(() => _filter = _played),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: shown.isEmpty
                        ? Text(
                            data.characters.isEmpty
                                ? 'No characters yet. Import a character card, '
                                      'or make one with the button above.'
                                : 'Nobody here.',
                            style: TextStyle(color: palette.textMuted),
                          )
                        : ListView(
                            children: [
                              for (final c in shown)
                                _CharacterRow(
                                  character: c,
                                  data: data,
                                  on: c.id == picked?.id,
                                  onTap: () => widget.onSelect(c.id),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: picked == null
                  ? const SizedBox()
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _Sheet(
                        key: ValueKey(picked.id),
                        character: picked,
                        data: data,
                        onDeleted: () => widget.onSelect(null),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CharacterRow extends StatelessWidget {
  const _CharacterRow({
    required this.character,
    required this.data,
    required this.on,
    required this.onTap,
  });

  final VocesCharacter character;
  final VocesData data;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: on ? accent.withValues(alpha: 0.16) : Colors.transparent,
            border: Border.all(
              color: on ? accent.withValues(alpha: 0.45) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              VocesAvatar(
                name: character.name,
                seed: character.art,
                file: data.library.portraitOf(character),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      character.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: palette.text,
                      ),
                    ),
                    if (character.line.isNotEmpty)
                      Text(
                        character.line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    super.key,
    required this.character,
    required this.data,
    required this.onDeleted,
  });

  final VocesCharacter character;
  final VocesData data;
  final VoidCallback onDeleted;

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete ${character.name}?',
      body:
          'They leave your library and every world. Stories already started '
          'keep their own copy.',
    );
    if (!ok) return;
    for (final w in data.worlds) {
      if (w.castIds.contains(character.id)) {
        await data.library.saveWorld(
          w.copyWith(castIds: [...w.castIds]..remove(character.id)),
        );
      }
    }
    await data.library.deleteCharacter(character.id);
    onDeleted();
    await data.reload();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final c = character;
    final worlds = data.worlds.where((w) => w.castIds.contains(c.id)).toList();
    final uses = [
      for (final s in data.stories)
        if (s.playerId == c.id)
          (s.title, 'You play them')
        else if (data.world(s.worldId)?.castIds.contains(c.id) ?? false)
          (s.title, 'The AI plays them'),
    ];
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    return VocesBox(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final avatar = VocesAvatar(
                name: c.name,
                seed: c.art,
                file: data.library.portraitOf(c),
                size: 88,
                radius: 22,
              );
              final about = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: palette.text,
                    ),
                  ),
                  if (c.line.isNotEmpty)
                    Text(c.line, style: muted.copyWith(fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (c.pronouns != null) VocesPill(c.pronouns!),
                      for (final t in c.tags) VocesPill(t),
                    ],
                  ),
                ],
              );
              final buttons = [
                IconButton(
                  tooltip: 'Edit',
                  onPressed: () => editCharacter(context, data, c),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _delete(context),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ];
              // In a narrow window the name goes under the portrait.
              if (box.maxWidth < 380) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [avatar, const Spacer(), ...buttons]),
                    const SizedBox(height: 12),
                    about,
                  ],
                );
              }
              return Row(
                children: [
                  avatar,
                  const SizedBox(width: 16),
                  Expanded(child: about),
                  ...buttons,
                ],
              );
            },
          ),
          for (final s in c.sections) ...[
            const SizedBox(height: 18),
            VocesLabel(s.heading),
            const SizedBox(height: 6),
            SelectableText(
              s.text,
              style: TextStyle(fontSize: 13, height: 1.55, color: palette.text),
            ),
          ],
          const SizedBox(height: 18),
          const VocesLabel('In worlds'),
          const SizedBox(height: 6),
          Text(
            worlds.isEmpty
                ? 'Not in a world yet. Add them from a world\'s Edit.'
                : worlds.map((w) => w.name).join(', '),
            style: TextStyle(fontSize: 13, color: palette.text),
          ),
          const SizedBox(height: 18),
          const VocesLabel('In your stories'),
          const SizedBox(height: 6),
          if (uses.isEmpty)
            Text('Not in a story yet.', style: muted)
          else
            for (final (title, role) in uses)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title, style: TextStyle(color: palette.text)),
                    ),
                    Text(role, style: muted),
                  ],
                ),
              ),
          const SizedBox(height: 8),
          Text(
            'Who you play is picked when a story starts and stays fixed for '
            'that story. There, the AI never voices them.',
            style: muted,
          ),
          if (c.source.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Imported from ${c.source}.', style: muted),
          ],
        ],
      ),
    );
  }
}

/// The usual parts of a sheet, offered when making a character.
const _starterSections = [
  'Who they are',
  'Personality',
  'Looks',
  'How they talk',
];

/// Makes a new character ([character] null) or edits one.
Future<VocesCharacter?> editCharacter(
  BuildContext context,
  VocesData data,
  VocesCharacter? character,
) => openEditor<VocesCharacter>(
  context,
  (done) => _CharacterEditor(data: data, character: character, done: done),
);

class _CharacterEditor extends StatefulWidget {
  const _CharacterEditor({
    required this.data,
    required this.character,
    required this.done,
  });

  final VocesData data;
  final VocesCharacter? character;
  final void Function(VocesCharacter?) done;

  @override
  State<_CharacterEditor> createState() => _CharacterEditorState();
}

typedef _SectionFields = (TextEditingController, TextEditingController);

class _CharacterEditorState extends State<_CharacterEditor> {
  final _name = TextEditingController();
  final _line = TextEditingController();
  final _pronouns = TextEditingController();
  final _tags = TextEditingController();
  final _looksTags = TextEditingController();
  final _sections = <_SectionFields>[];

  /// The model is turning the Looks part into picture tags.
  var _tagging = false;

  /// "Describe them" writes for adults.
  var _describeAdult = false;
  var _art = VocesLibrary.newArt();

  /// A new portrait, uploaded or drawn.
  File? _portrait;

  /// The old portrait is to go, for the colours.
  var _cleared = false;
  var _saving = false;

  late final String _start;
  late final int _firstArt;
  VocesDraft? _restored;
  var _finished = false;

  VocesLibrary get _library => widget.data.library;
  String get _draftKey =>
      VocesLibrary.draftKey('character', widget.character?.id);

  @override
  void initState() {
    super.initState();
    _load(widget.character);
    _firstArt = _art;
    _start = _fingerprint();
    final draft = _library.draft(_draftKey);
    if (draft != null) {
      _restored = draft;
      _load(VocesCharacter.fromJson(draft.item));
      _portrait = draft.picture?.existsSync() == true ? draft.picture : null;
      _cleared = draft.cleared;
    }
  }

  void _load(VocesCharacter? c) {
    _name.text = c?.name ?? '';
    _line.text = c?.line ?? '';
    _pronouns.text = c?.pronouns ?? '';
    _tags.text = c?.tags.join(', ') ?? '';
    _looksTags.text = c?.looksTags.join(', ') ?? '';
    _setSections([
      if (c == null)
        for (final h in _starterSections) SheetSection(h, '')
      else
        ...c.sections,
    ]);
    _art = c?.art ?? _art;
  }

  void _setSections(List<SheetSection> sections) {
    final old = [..._sections];
    _sections
      ..clear()
      ..addAll([
        for (final s in sections)
          (
            TextEditingController(text: s.heading),
            TextEditingController(text: s.text),
          ),
      ]);
    // The old fields may still be on screen until the next frame.
    if (old.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final (a, b) in old) {
          a.dispose();
          b.dispose();
        }
      });
    }
  }

  /// The character as it stands in the editor; [raw] keeps empty parts,
  /// for a draft.
  VocesCharacter _current({bool raw = false}) {
    final base =
        widget.character ??
        VocesCharacter(id: '', name: '', created: DateTime.now());
    final pronouns = _pronouns.text.trim();
    return VocesCharacter(
      id: base.id,
      name: _name.text.trim(),
      line: _line.text.trim(),
      pronouns: pronouns.isEmpty ? null : pronouns,
      tags: splitTags(_tags.text),
      looksTags: splitTags(_looksTags.text),
      sections: [
        for (final (h, t) in _sections)
          if (raw)
            SheetSection(h.text, t.text)
          else if (t.text.trim().isNotEmpty)
            SheetSection(
              h.text.trim().isEmpty ? 'Notes' : h.text.trim(),
              t.text.trim(),
            ),
      ],
      portrait: base.portrait,
      art: _art,
      source: base.source,
      created: base.created,
    );
  }

  void _keepDraft() {
    _portrait = _library.keepDraft(
      _draftKey,
      _current(raw: true).toJson(),
      picture: _portrait,
      cleared: _cleared,
    );
  }

  void _dropDraft() {
    dropDrawn(_library, _portrait);
    setState(() {
      _load(widget.character);
      _art = _firstArt;
      _portrait = null;
      _cleared = false;
      _restored = null;
    });
    unawaited(_library.dropDraft(_draftKey).then((_) => widget.data.reload()));
  }

  Future<void> _cancel() async {
    if (_fingerprint() != _start) {
      final choice = await askLeave(context);
      if (choice == null || !mounted) return;
      if (choice == LeaveChoice.draft) {
        _keepDraft();
      } else {
        await _library.dropDraft(_draftKey);
      }
    } else if (_restored != null) {
      await _library.dropDraft(_draftKey);
    }
    _finished = true;
    unawaited(widget.data.reload());
    widget.done(null);
  }

  File? get _shown =>
      _portrait ??
      (_cleared || widget.character == null
          ? null
          : _library.portraitOf(widget.character!));

  @override
  void dispose() {
    // Left without Cancel or Save: what was typed waits as a draft.
    if (!_finished && _fingerprint() != _start) {
      _keepDraft();
      unawaited(widget.data.reload());
    }
    for (final c in [_name, _line, _pronouns, _tags, _looksTags]) {
      c.dispose();
    }
    dropDrawn(_library, _portrait);
    for (final (a, b) in _sections) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  /// "Describe them": the chat model fills the sheet in from [idea].
  Future<String?> _describe(String idea) {
    final services = AppScope.of(context);
    return describeError(() async {
      final reply = await services.models.ask(
        CharacterDescriber.instructions(adult: _describeAdult),
        CharacterDescriber.brief(idea, adult: _describeAdult),
        maxTokens: 1600,
        what: 'Describe the character',
      );
      final got = CharacterDescriber.parse(reply);
      if (got == null) return 'The model gave nothing usable. Try again.';
      if (!mounted) return null;
      setState(() {
        _name.text = got.name;
        _pronouns.text = got.pronouns;
        _line.text = got.line;
        _tags.text = got.traits.join(', ');
        _looksTags.text = got.looksTags.join(', ');
        // Parts the human added by hand stay, after the model's.
        final own = [
          for (final (h, t) in _sections)
            if (t.text.trim().isNotEmpty &&
                !CharacterDescriber.parts.contains(h.text.trim()))
              SheetSection(h.text, t.text),
        ];
        _setSections([...got.sections, ...own]);
      });
      return null;
    });
  }

  /// "From Looks": the chat model turns the Looks part into picture tags.
  Future<void> _tagLooks() async {
    final looks = looksText([
      for (final (h, t) in _sections) SheetSection(h.text, t.text),
    ]).trim();
    final messenger = ScaffoldMessenger.of(context);
    if (looks.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Write how they look in the Looks part first.'),
        ),
      );
      return;
    }
    final services = AppScope.of(context);
    setState(() => _tagging = true);
    final error = await describeError(() async {
      final reply = await services.models.ask(
        LooksTags.fromLooksInstructions,
        LooksTags.fromLooksBrief(looks, pronouns: _pronouns.text),
        maxTokens: 300,
        what: 'Looks tags',
        exact: true,
      );
      final tags = LooksTags.parse(reply);
      if (tags.isEmpty) return 'The model gave no tags. Try again.';
      if (mounted) _looksTags.text = tags.join(', ');
      return null;
    });
    if (!mounted) return;
    setState(() => _tagging = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final lib = _library;
    var saved = await lib.saveCharacter(_current());
    if (_portrait != null) {
      final name = await lib.adoptPortrait(saved.id, _portrait!);
      saved = await lib.saveCharacter(saved.copyWith(portrait: name));
    } else if (_cleared && saved.portrait != null) {
      await lib.removePortrait(saved.id);
      saved = await lib.saveCharacter(saved.copyWith(clearPortrait: true));
    }
    await forgetPicture(lib.portraitOf(saved));
    _finished = true;
    await lib.dropDraft(_draftKey);
    await widget.data.reload();
    widget.done(saved);
  }

  /// Everything the editor would save, to tell whether anything changed.
  String _fingerprint() => [
    _name.text,
    _line.text,
    _pronouns.text,
    _tags.text,
    _looksTags.text,
    for (final (h, t) in _sections) '${h.text}\u0000${t.text}',
    _art,
    _portrait?.path,
    _cleared,
  ].join('\u0001');

  @override
  Widget build(BuildContext context) {
    InputDecoration field(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: true,
    );
    return ListenableBuilder(
      listenable: _name,
      builder: (context, _) => VocesEditorPage(
        title: widget.character == null
            ? 'New character'
            : 'Edit ${widget.character!.name}',
        saveLabel: widget.character == null ? 'Create' : 'Save',
        onCancel: _cancel,
        onSave: _saving || _name.text.trim().isEmpty ? null : _save,
        banner: _restored == null
            ? null
            : DraftBanner(saved: _restored!.saved, onDrop: _dropDraft),
        preview: _preview(context),
        sections: [
          EditorSection(
            'Basics',
            Icons.badge_outlined,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.character == null) ...[
                  DescribeBox(
                    title: 'Describe them',
                    what: 'character',
                    hint:
                        'e.g. a retired lighthouse keeper who talks to the '
                        'fog and knows every smuggler by name',
                    onDescribe: _describe,
                    adult: _describeAdult,
                    onAdult: (on) => setState(() => _describeAdult = on),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _name,
                        autofocus:
                            widget.character == null && _restored == null,
                        decoration: field('Name'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _pronouns,
                        decoration: field('Pronouns', hint: 'she/her'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _line,
                  decoration: field(
                    'In one line',
                    hint: 'Smuggler captain, owes no one',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _tags,
                  decoration: field('Traits', hint: 'bold, witty, secretive'),
                ),
              ],
            ),
          ),
          EditorSection(
            'Portrait',
            Icons.face_retouching_natural_rounded,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _looksTags,
                  minLines: 1,
                  maxLines: 4,
                  decoration:
                      field(
                        'Physical tags',
                        hint:
                            'black hair, undercut, green eyes, leather jacket',
                      ).copyWith(
                        helperText:
                            'How they look as picture tags; Draw it starts '
                            'from these.',
                        suffixIcon: Tooltip(
                          message: 'Make tags from the Looks part',
                          child: IconButton(
                            icon: _tagging
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.auto_awesome_rounded),
                            onPressed: _tagging ? null : _tagLooks,
                          ),
                        ),
                      ),
                ),
                const SizedBox(height: 14),
                VocesPictureField(
                  name: _name.text,
                  seed: _art,
                  file: _shown,
                  wide: false,
                  drawingFolder: _library.drawingFolder,
                  prompt: () => characterPrompt(
                    pronouns: _pronouns.text,
                    looksTags: splitTags(_looksTags.text),
                    sections: [
                      for (final (h, t) in _sections)
                        SheetSection(h.text, t.text),
                    ],
                  ),
                  onSeed: (seed) => setState(() => _art = seed),
                  onFile: (f) => setState(() {
                    if (f != _portrait) dropDrawn(_library, _portrait);
                    _portrait = f;
                    _cleared = f == null;
                  }),
                ),
              ],
            ),
          ),
          EditorSection(
            'Sheet',
            Icons.article_outlined,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'What the AI keeps in mind when it plays them. Each part '
                  'has a heading of your own; rename, remove or add parts '
                  'as you like.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textMuted,
                  ),
                ),
                for (var i = 0; i < _sections.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _sections[i].$1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  contentPadding: EdgeInsets.fromLTRB(
                                    4,
                                    8,
                                    4,
                                    8,
                                  ),
                                  hintText: 'Heading',
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove this part',
                              onPressed: () =>
                                  setState(() => _sections.removeAt(i)),
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                          ],
                        ),
                        TextField(
                          controller: _sections[i].$2,
                          minLines: 2,
                          maxLines: 10,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(
                      () => _sections.add((
                        TextEditingController(),
                        TextEditingController(),
                      )),
                    ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add a part'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Their sheet as it will read, as it's typed.
  Widget _preview(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _line,
      _pronouns,
      _tags,
      for (final (h, t) in _sections) ...[h, t],
    ]),
    builder: (context, _) {
      final palette = context.palette;
      final c = _current();
      final name = c.name.isEmpty ? 'Unnamed' : c.name;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VocesLabel('Their sheet'),
          const SizedBox(height: 8),
          VocesBox(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    VocesAvatar(
                      name: name,
                      seed: _art,
                      file: _shown,
                      size: 64,
                      radius: 18,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: palette.text,
                            ),
                          ),
                          if (c.pronouns != null)
                            Text(
                              c.pronouns!,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.textMuted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (c.line.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(c.line, style: TextStyle(color: palette.text)),
                ],
                if (c.tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (final t in c.tags) VocesPill(t)],
                  ),
                ],
                for (final s in c.sections) ...[
                  const SizedBox(height: 14),
                  Text(
                    s.heading,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.text,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: palette.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );
}
