import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../data/voces/story_log.dart';
import '../../services/logs/app_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/voces/describer.dart';
import '../../services/images/picture_info.dart';
import '../../services/voces/living_cast.dart';
import '../../services/voces/scene_tags.dart';
import '../../services/voces/story_engine.dart';
import '../../services/voces/story_export.dart';
import '../../services/voces/story_notes.dart';
import 'story_text.dart';
import 'world_update_dialog.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import 'voces_editor.dart';
import 'voces_home.dart';
import 'voces_picture.dart';
import 'voces_widgets.dart';

/// Asks how to start a story in [world], starts it and opens it.
Future<void> startStoryIn(
  BuildContext context,
  VocesData data,
  VocesWorld world,
) async {
  final plan = await showDialog<_StoryPlan>(
    context: context,
    builder: (_) => _NewStoryDialog(data: data, world: world),
  );
  if (plan == null || !context.mounted) return;
  final story = await data.library.startStory(
    world: world,
    player: plan.player,
    title: plan.title,
    difficulty: plan.difficulty,
    opening: plan.opening,
  );
  await data.reload();
  if (!context.mounted) return;
  await playStory(context, data, story, cast: plan.cast);
}

/// Opens [story] in the main panel. [cast] is who is there at the start,
/// for a story not played yet.
Future<void> playStory(
  BuildContext context,
  VocesData data,
  StorySave story, {
  List<String>? cast,
}) => openEditor<void>(
  context,
  (done) => StoryView(data: data, story: story, cast: cast, done: done),
);

class _StoryPlan {
  const _StoryPlan({
    required this.title,
    required this.player,
    required this.difficulty,
    required this.opening,
    required this.cast,
  });

  final String title;
  final VocesCharacter player;
  final Difficulty difficulty;
  final Opening? opening;
  final List<String> cast;
}

class _NewStoryDialog extends StatefulWidget {
  const _NewStoryDialog({required this.data, required this.world});

  final VocesData data;
  final VocesWorld world;

  @override
  State<_NewStoryDialog> createState() => _NewStoryDialogState();
}

class _NewStoryDialogState extends State<_NewStoryDialog> {
  final _title = TextEditingController();
  var _titleTouched = false;
  VocesCharacter? _player;
  var _difficulty = Difficulty.neutral;
  Opening? _opening;
  late Set<String> _cast;

  VocesWorld get world => widget.world;

  List<VocesCharacter> get _castHere => [
    for (final id in world.castIds)
      if (widget.data.character(id) != null && id != _player?.id)
        widget.data.character(id)!,
  ];

  @override
  void initState() {
    super.initState();
    final played = {for (final s in widget.data.stories) s.playerId};
    // Someone outside the world's cast, ideally one already played.
    final outside = [
      for (final c in widget.data.characters)
        if (!world.castIds.contains(c.id)) c,
    ];
    _player =
        outside.where((c) => played.contains(c.id)).firstOrNull ??
        outside.firstOrNull ??
        widget.data.characters.firstOrNull;
    _opening = world.openings.firstOrNull;
    _cast = _castHere.take(3).map((c) => c.id).toSet();
    _title.text = _suggestTitle();
  }

  String _suggestTitle() => _player == null
      ? world.name
      : '${_player!.name.split(' ').first} in ${world.name}';

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _pick(VocesCharacter? c) => setState(() {
    _player = c;
    _cast.remove(c?.id);
    if (!_titleTouched) _title.text = _suggestTitle();
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    final mature = widget.data.mature();
    final levels = [
      for (final d in Difficulty.values)
        if (!d.adultOnly || (world.adult && mature)) d,
    ];
    final ready = _player != null && _title.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text('A new story in ${world.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (_) => setState(() => _titleTouched = true),
              ),
              const SizedBox(height: 18),
              const VocesLabel('Who you play'),
              const SizedBox(height: 8),
              if (widget.data.characters.isEmpty)
                Text(
                  'Make a character first (Characters → New character): '
                  'that\'s who you\'ll be.',
                  style: muted,
                )
              else
                LayoutBuilder(
                  builder: (context, box) => GlassSelect<String?>(
                    value: _player?.id,
                    width: box.maxWidth,
                    placeholder: 'Pick who you play',
                    options: [
                      for (final c in widget.data.characters)
                        GlassOption(
                          c.id,
                          c.line.isEmpty ? c.name : '${c.name} · ${c.line}',
                        ),
                    ],
                    onChanged: (id) =>
                        _pick(id == null ? null : widget.data.character(id)),
                  ),
                ),
              const SizedBox(height: 18),
              const VocesLabel('Difficulty'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final d in levels)
                    VocesPill(
                      d.label,
                      on: d == _difficulty,
                      onTap: () => setState(() => _difficulty = d),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(_difficulty.blurb, style: muted),
              const SizedBox(height: 18),
              const VocesLabel('How it begins'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final o in world.openings)
                    VocesPill(
                      o.title.isEmpty ? 'Untitled opening' : o.title,
                      on: _opening == o,
                      onTap: () => setState(() => _opening = o),
                    ),
                  VocesPill(
                    'Let the narrator begin',
                    on: _opening == null,
                    onTap: () => setState(() => _opening = null),
                  ),
                ],
              ),
              if (_castHere.isNotEmpty) ...[
                const SizedBox(height: 18),
                const VocesLabel('Who\'s there at the start'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in _castHere)
                      VocesPill(
                        c.name,
                        on: _cast.contains(c.id),
                        onTap: () => setState(
                          () => _cast.contains(c.id)
                              ? _cast.remove(c.id)
                              : _cast.add(c.id),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('The others may turn up as the story goes.', style: muted),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: ready
              ? () => Navigator.pop(
                  context,
                  _StoryPlan(
                    title: _title.text.trim(),
                    player: _player!,
                    difficulty: _difficulty,
                    opening: _opening,
                    cast: [
                      for (final c in _castHere)
                        if (_cast.contains(c.id)) c.id,
                    ],
                  ),
                )
              : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Begin'),
        ),
      ],
    );
  }
}

/// How the human's next line goes in.
enum _Mode {
  play('You', TurnKind.say, '"What you say" and *what you do*'),
  ask('Ask the narrator', TurnKind.ask, 'Ask for something: "let night fall"');

  const _Mode(this.label, this.kind, this.hint);
  final String label;
  final TurnKind kind;
  final String hint;
}

/// A story being played, in the main panel.
class StoryView extends StatefulWidget {
  const StoryView({
    super.key,
    required this.data,
    required this.story,
    required this.done,
    this.cast,
  });

  final VocesData data;
  final StorySave story;
  final List<String>? cast;
  final void Function(void) done;

  @override
  State<StoryView> createState() => _StoryViewState();
}

class _StoryViewState extends State<StoryView> {
  StoryLog? _log;
  StoryEngine? _engine;
  var _turns = <StoryTurn>[];
  var _state = const StoryState();
  late StorySave _story = widget.story;
  Object? _error;

  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  var _mode = _Mode.play;

  /// The side column, shown on demand in narrow windows.
  var _sideOpen = false;

  /// Whoever the human picked to answer; null lets the story decide.
  String? _answerer;
  var _answererSet = false;

  /// The reply being written, and by whom.
  var _busy = false;
  String? _writer;
  final _writing = StringBuffer();

  /// Narration since the cast was last tended, people to stow, and
  /// extras whose sheet is being written.
  final _newNarration = <String>[];
  final _toStow = <String>{};
  final _sheets = <String>{};
  var _tending = false;
  StreamSubscription<String>? _stream;
  Completer<bool>? _streamDone;
  var _jumpIn = false;

  VocesLibrary get library => widget.data.library;
  late final _services = AppScope.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  Future<void> _open() async {
    final services = _services;
    try {
      final world = await library.storyWorld(widget.story);
      final log = await services.openStoryLog(widget.story.id);
      if (!mounted) {
        await log.close();
        return;
      }
      final engine = StoryEngine(
        world,
        mature: services.settings.value.vocesMature,
      );
      final saved = (await log.state())['story'];
      final turns = await log.turns();
      final StoryState state;
      if (saved is Map) {
        state = StoryState.fromJson(saved.cast<String, Object?>());
      } else {
        state = StoryState(present: engine.startingCast(widget.cast));
        await log.setState('story', state.toJson());
      }
      setState(() {
        _log = log;
        _engine = engine;
        _state = state;
        _turns = turns;
      });
      final now = DateTime.now();
      if (StoryEngine.wantsRecap(
        turns,
        now,
        lastRecap: _recappedAt[widget.story.id],
      )) {
        _recappedAt[widget.story.id] = now;
        unawaited(_makeRecap());
      }
      if (turns.isEmpty) {
        final opening = world.world.openings
            .where((o) => o.title == widget.story.opening)
            .firstOrNull;
        if (opening != null && opening.text.trim().isNotEmpty) {
          final split = StoryEngine.splitPlace(opening.text);
          if (split.place != null) await _setPlace(split.place!);
          await _add(TurnKind.narrator, split.text);
        } else {
          await _run(null, chain: false);
        }
      }
      _toEnd(jump: true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _stream?.cancel();
    _log?.close();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    widget.data.reload();
    super.dispose();
  }

  Future<void> _saveState(StoryState s) async {
    setState(() => _state = s);
    await _log?.setState('story', s.toJson());
  }

  Future<void> _setPlace(String place) async {
    await _saveState(_state.copyWith(place: place));
  }

  Future<StoryTurn> _add(
    TurnKind kind,
    String text, {
    String? speakerId,
    String speaker = '',
  }) async {
    final turn = await _log!.add(
      kind,
      text,
      speakerId: speakerId,
      speaker: speaker,
    );
    if (!mounted) return turn;
    setState(() => _turns = [..._turns, turn]);
    if (_state.extras.isNotEmpty && !kind.aside) {
      unawaited(
        _saveState(
          _state.copyWith(extras: LivingCast.count(_state.extras, turn)),
        ),
      );
    }
    _story = _story.copyWith(
      lastPlayed: DateTime.now(),
      turns: _turns.where((t) => !t.kind.aside).length,
      place: _state.place,
    );
    unawaited(library.saveStory(_story));
    _toEnd();
    return turn;
  }

  void _toEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  /// A small button that puts [mark] around the selected words, or a
  /// pair of them at the cursor to type between.
  Widget _markButton(String mark, String tip) => Tooltip(
    message: tip,
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        _input.value = wrapWithMark(_input.value, mark);
        _inputFocus.requestFocus();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          mark == '"' ? '" "' : '* *',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: context.palette.textMuted,
          ),
        ),
      ),
    ),
  );

  /// The human's line, then whoever answers, and the chain after.
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    final engine = _engine!;
    final before = _turns;
    final turn = await _add(_mode.kind, text);
    if (_rollNext || Fortune.rollsOnItsOwn(turn, _story.difficulty)) {
      await _saveState(
        _state.copyWith(rolls: {..._state.rolls, turn.id: Fortune.roll()}),
      );
    }
    if (_rollNext && mounted) setState(() => _rollNext = false);
    final who = _answererSet
        ? _answerer
        : engine.whoAnswers(turn, before, _state);
    await _run(who);
  }

  /// "Continue": the story goes on without the human.
  Future<void> _continue() async {
    if (_busy) return;
    final who = _answererSet
        ? _answerer
        : _engine!.whoContinues(_turns, _state);
    await _run(who);
  }

  /// Writes [first]'s reply, then lets those it names answer, up to the
  /// chain's length or until the human jumps in.
  Future<void> _run(String? first, {bool chain = true}) async {
    setState(() {
      _busy = true;
      _jumpIn = false;
    });
    try {
      String? speaker = first;
      var left = chain ? _state.chain : 0;
      while (mounted) {
        final reply = await _reply(speaker);
        if (reply == null || _jumpIn || left-- <= 0) break;
        final next = _engine!.chainsTo(reply, speaker, _state);
        if (next == null) break;
        speaker = next;
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _writer = null;
        });
        unawaited(_tendCast());
        unawaited(_keepNotes());
      }
    }
  }

  /// The composer's dice: the next turn gets a roll (a lie, a sneak…).
  var _rollNext = false;
  var _notesBusy = false;

  /// Brings the story notes up to date every [StoryNotes.every] told
  /// turns, or now when [force]. Waits for replies; uses the chat model.
  Future<void> _keepNotes({bool force = false}) async {
    final engine = _engine;
    if (engine == null || _notesBusy || _busy || !mounted) return;
    final fresh = [
      for (final t in _turns)
        if (t.id > _state.notesAt && t.id >= 0 && !t.kind.aside) t,
    ];
    if (fresh.isEmpty || (!force && fresh.length < StoryNotes.every)) return;
    setState(() => _notesBusy = true);
    try {
      final reply = await _services.askModel(
        StoryNotes.instructions(engine.playerName),
        StoryNotes.brief(
          _state.notes,
          engine.playerName,
          engine.transcript(fresh),
        ),
        maxTokens: 900,
        what: 'Story notes',
        exact: true,
      );
      final notes = reply == null ? null : StoryNotes.parse(reply);
      if (notes != null && mounted) {
        await _saveState(_state.copyWith(notes: notes, notesAt: fresh.last.id));
      } else if (force && mounted) {
        _say('The notes couldn\'t be updated this time.');
      }
    } on Object catch (e) {
      _services.log.add(LogKind.errors, 'Story notes failed: $e');
    } finally {
      if (mounted) setState(() => _notesBusy = false);
    }
  }

  Future<void> _editNotes() async {
    final n = _state.notes;
    final items = TextEditingController(text: n.itemsText);
    final quests = TextEditingController(text: n.questsText);
    final feelings = TextEditingController(text: n.feelingsText);
    Widget field(TextEditingController c, String label, String hint) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        minLines: 2,
        maxLines: 6,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: true,
        ),
      ),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Story notes'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                field(items, 'Carrying', 'One thing per line'),
                field(quests, 'Still to do', 'One goal or promise per line'),
                field(feelings, 'How people feel', 'Mira: wary, but warming'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _saveState(
        _state.copyWith(
          notes: StoryNotes.fromText(
            items: items.text,
            quests: quests.text,
            feelings: feelings.text,
          ),
        ),
      );
    }
    items.dispose();
    quests.dispose();
    feelings.dispose();
  }

  /// Between turns: notices people the narrator named, gives a sheet to
  /// the ones who came up often or were talked to, and notes what those
  /// who left went through. Uses the chat model, so it waits for replies.
  Future<void> _tendCast() async {
    if (_tending || !mounted) return;
    _tending = true;
    try {
      while (mounted && !_busy && _newNarration.isNotEmpty) {
        final text = _newNarration.join('\n\n');
        _newNarration.clear();
        await _findExtras(text);
      }
      for (final id in [..._toStow]) {
        if (!mounted || _busy) break;
        _toStow.remove(id);
        await _stow(id);
      }
      for (final e in [..._state.extras]) {
        if (!mounted || _busy) break;
        if (LivingCast.ripe(e)) await _promote(e);
      }
    } finally {
      _tending = false;
    }
  }

  Set<String> get _known => {
    _engine!.playerName,
    for (final c in _engine!.world.cast.values) c.name,
    for (final e in _state.extras) e.name,
  };

  Future<void> _findExtras(String text) async {
    final known = _known;
    if (LivingCast.candidates(text, known).isEmpty) return;
    try {
      final reply = await _services.askModel(
        LivingCast.finderInstructions,
        LivingCast.finderBrief(text, known.toList()),
        maxTokens: 400,
        what: 'Who is new in the story',
        exact: true,
      );
      if (reply == null || !mounted) return;
      final found = [
        for (final e in LivingCast.parseFound(reply, known))
          if (LivingCast.names(text, e.name)) e,
      ];
      if (found.isEmpty) return;
      await _saveState(
        _state.copyWith(extras: LivingCast.merge(_state.extras, found)),
      );
    } on Object catch (e) {
      _note('Voces Mundi couldn\'t look for new people in the story', e);
    }
  }

  void _note(String what, Object e) =>
      _services.log.add(LogKind.errors, what, details: '$e', error: true);

  /// Gives extra [e] a sheet written from their moments in the story; from
  /// then on they speak for themselves.
  Future<void> _promote(Extra e) async {
    if (!_sheets.add(e.name)) return;
    setState(() {});
    try {
      final engine = _engine!;
      final moments = LivingCast.excerpts(
        e.name,
        _turns,
        playerName: engine.playerName,
      );
      final reply = await _services.askModel(
        CharacterDescriber.instructions(
          adult: engine.mature && engine.world.world.adult,
        ),
        CharacterDescriber.brief(
          LivingCast.sheetIdea(e, moments),
          adult: engine.mature && engine.world.world.adult,
        ),
        what: 'A sheet for someone met in the story',
      );
      final d = reply == null ? null : CharacterDescriber.parse(reply);
      if (d == null || !mounted) return;
      final c = await library.saveStoryCharacter(
        _story,
        VocesCharacter(
          id: '',
          name: e.name,
          line: d.line.isEmpty ? e.line : d.line,
          pronouns: d.pronouns.isEmpty ? null : d.pronouns,
          tags: d.traits,
          looksTags: d.looksTags,
          sections: d.sections,
          source: 'Met in "${_story.title}"',
          created: DateTime.now(),
        ),
      );
      if (!mounted) return;
      engine.world.cast[c.id] = c;
      final present = _state.present.contains(c.id)
          ? _state.present
          : [..._state.present, c.id];
      await _saveState(
        _state.copyWith(
          present: present,
          extras: [
            for (final x in _state.extras)
              if (x.name != e.name) x,
          ],
        ),
      );
      await _add(
        TurnKind.scene,
        '${c.name} now speaks for themselves',
        speakerId: c.id,
      );
    } on Object catch (err) {
      _note('Voces Mundi couldn\'t write a sheet for ${e.name}', err);
    } finally {
      _sheets.remove(e.name);
      if (mounted) setState(() {});
    }
  }

  /// Notes on [id]'s sheet what they went through, so they come back as
  /// they left.
  Future<void> _stow(String id) async {
    final engine = _engine!;
    final c = engine.world.cast[id];
    if (c == null) return;
    final moments = LivingCast.excerpts(
      c.name,
      _turns,
      playerName: engine.playerName,
    );
    if (moments.isEmpty) return;
    try {
      final reply = await _services.askModel(
        LivingCast.pastInstructions,
        LivingCast.pastBrief(c.name, moments),
        maxTokens: 400,
        what: 'A character\'s past',
      );
      final past = reply
          ?.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .trim();
      if (past == null || past.isEmpty || !mounted) return;
      final saved = await library.saveStoryCharacter(
        _story,
        c.copyWith(
          sections: [
            for (final s in c.sections)
              if (s.heading != LivingCast.pastHeading) s,
            SheetSection(LivingCast.pastHeading, past),
          ],
        ),
      );
      engine.world.cast[id] = saved;
    } on Object catch (e) {
      _note('Voces Mundi couldn\'t note what ${c.name} went through', e);
    }
  }

  /// Copies a story's character into Characters, for other worlds.
  Future<void> _saveToCharacters(String id) async {
    final c = _engine!.world.cast[id];
    if (c == null) return;
    final taken = {
      for (final x in widget.data.characters) x.name.toLowerCase(),
    };
    var name = c.name;
    for (var n = 2; taken.contains(name.toLowerCase()); n++) {
      name = '${c.name} $n';
    }
    final saved = await library.copyFromStory(_story, c, name: name);
    await widget.data.reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${saved.name} is in your Characters now.')),
    );
  }

  /// One reply by [speaker] (null: the narrator); its text once kept,
  /// null when it was stopped or failed.
  Future<String?> _reply(String? speaker) async {
    final engine = _engine!;
    CastChange? change;
    if (speaker == null) {
      change = engine.rollChange(_state);
      if (change != null) {
        final present = [..._state.present];
        change.arrives
            ? present.add(change.who.id)
            : present.remove(change.who.id);
        await _saveState(_state.copyWith(present: present));
        await _add(TurnKind.scene, change.line, speakerId: change.who.id);
        if (!change.arrives) _toStow.add(change.who.id);
      }
    }
    final prompt = engine.prompt(
      speaker,
      _turns,
      _state,
      change: change,
      byMeaning: await _loreByMeaning(),
    );
    if (!mounted) return null;
    setState(() {
      _writer = speaker;
      _writing.clear();
    });
    final finished = Completer<bool>();
    _streamDone = finished;
    Object? failed;
    _stream = _services
        .streamModel(prompt.system, prompt.user, stop: prompt.stop)
        .listen(
          (piece) {
            if (!mounted) return;
            setState(() => _writing.write(piece));
            _toEnd(jump: true);
          },
          onError: (Object e) {
            failed = e;
            if (!finished.isCompleted) finished.complete(false);
          },
          onDone: () {
            if (!finished.isCompleted) finished.complete(true);
          },
          cancelOnError: true,
        );
    final whole = await finished.future;
    _stream = null;
    if (!mounted) return null;
    var text = engine.clean(_writing.toString(), speaker);
    setState(() => _writing.clear());
    if (failed != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The model stopped: ${_short(failed!)}')),
      );
    }
    if (speaker == null) {
      final split = StoryEngine.splitPlace(text);
      if (split.place != null) await _setPlace(split.place!);
      text = split.text;
    }
    if (text.isEmpty) return null;
    await _add(
      speaker == null ? TurnKind.narrator : TurnKind.character,
      text,
      speakerId: speaker,
      speaker: speaker == null ? '' : engine.nameOf(speaker),
    );
    if (speaker == null) _newNarration.add(text);
    return whole && failed == null ? text : null;
  }

  /// Lore entries close in meaning to the last few turns, found with the
  /// Recall model when it's downloaded; none otherwise, or on any trouble
  /// (key words still work then).
  Future<List<LoreEntry>> _loreByMeaning() async {
    final engine = _engine!;
    final entries = engine.loreEntries;
    final recall = _services.recall;
    final text = engine.recentText(_turns);
    if (entries.isEmpty || text.trim().isEmpty || !recall.available()) {
      return const [];
    }
    try {
      final q =
          (await recall.embedder
                  .embed([text], query: true)
                  .timeout(const Duration(seconds: 20)))
              .single;
      final scores = await recall
          .similarity(q, [for (final e in entries) '${e.title}: ${e.text}'])
          .timeout(const Duration(seconds: 60));
      final order = [
        for (var i = 0; i < entries.length; i++)
          if (scores[i] >= StoryEngine.loreMinScore) i,
      ]..sort((a, b) => scores[b].compareTo(scores[a]));
      return [
        for (final i in order.take(StoryEngine.loreByMeaning)) entries[i],
      ];
    } on Object catch (e) {
      _services.log.add(
        LogKind.errors,
        'Voces Mundi couldn\'t look up lore by meaning; key words still work',
        details: '$e',
        error: true,
      );
      return const [];
    }
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// Stops the reply being written; what's there so far is kept.
  void _stop() {
    _jumpIn = true;
    _stream?.cancel();
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete(false);
  }

  /// Writes the last reply again.
  Future<void> _retry() async {
    final last = _turns.lastOrNull;
    if (last == null || _busy || last.kind.byHuman) return;
    if (last.kind.aside) return;
    await _log!.dropFrom(last.id);
    setState(() => _turns = _turns.where((t) => t.id < last.id).toList());
    await _run(
      last.kind == TurnKind.character ? last.speakerId : null,
      chain: false,
    );
  }

  Future<void> _edit(StoryTurn turn) async {
    final c = TextEditingController(text: turn.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit this turn'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: 4,
            maxLines: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    await _log!.edit(turn.id, text);
    setState(
      () => _turns = [
        for (final t in _turns) t.id == turn.id ? t.copyWith(text: text) : t,
      ],
    );
  }

  Future<void> _rewind(StoryTurn turn) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go back to here?'),
        content: const Text(
          'This turn and everything after it are removed. The story goes on '
          'from the turn before.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Go back'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _log!.dropFrom(turn.id);
    setState(() => _turns = _turns.where((t) => t.id < turn.id).toList());
  }

  var _drawing = false;

  /// "Previously on…": written when a story is opened after a break, or
  /// asked for from the menu; shown above the composer until closed.
  String? _recap;
  var _recapping = false;

  /// When each story last opened with a recap since VoxCordis started.
  static final _recappedAt = <String, DateTime>{};

  Future<void> _makeRecap() async {
    final engine = _engine;
    if (engine == null || _recapping || _busy) return;
    setState(() {
      _recapping = true;
      _recap = null;
    });
    String? text;
    try {
      final ask = engine.recap(_turns);
      final reply = await _services.askModel(
        ask.system,
        ask.user,
        maxTokens: 900,
        what: 'Previously on…',
      );
      text = reply
          ?.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .replaceFirst(
            RegExp(r'^\W*previously on[^\n]*\n', caseSensitive: false),
            '',
          )
          .trim();
    } on Object catch (e) {
      _services.log.add(LogKind.errors, 'Recap failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _recapping = false;
      _recap = text == null || text.isEmpty ? null : text;
    });
    if (_recap == null) _say('The recap couldn\'t be written this time.');
  }

  Widget _recapCard(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 6, 14),
            decoration: BoxDecoration(
              color: palette.bubble,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.history_edu_rounded, size: 18, color: accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Previously on ${_story.title}…',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: palette.text,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _recap = null;
                        _recapping = false;
                      }),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                if (_recap == null)
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'The narrator is catching you up…',
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ],
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text.rich(
                        storyText(
                          _recap!,
                          TextStyle(
                            fontSize: 14.5,
                            height: 1.5,
                            color: palette.text,
                          ),
                          palette.textMuted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What shows dimmed behind the turns: the latest scene picture, else the
  /// world's picture.
  File? _backdrop(StoryEngine engine) {
    if (!_services.settings.value.vocesBackdrop) return null;
    final scene = _turns.where((t) => t.kind == TurnKind.picture).lastOrNull;
    if (scene != null) {
      final f = File(p.join(engine.world.folder, scene.text));
      if (f.existsSync()) return f;
    }
    return engine.world.picture;
  }

  /// "Draw this" / "Draw the scene": the chat model turns the moment at
  /// [upTo] into picture tags (with the Physical tags of those in view),
  /// the Draw panel opens with them to change or draw, and the picture
  /// kept joins the story. The chat model loads again after.
  Future<void> _drawScene(StoryTurn upTo) async {
    final services = _services;
    final engine = _engine;
    if (engine == null || _busy || _drawing) return;
    if (services.settings.value.imageEngine == ImageEngineChoice.off) {
      _say('Turn on drawing in Settings → Images first.');
      return;
    }
    setState(() => _drawing = true);
    try {
      final adult = engine.mature && engine.world.world.adult;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Writing picture tags for the scene…'),
          duration: Duration(minutes: 2),
        ),
      );
      String prompt;
      try {
        final reply = await services.askModel(
          SceneTags.instructions(adult: adult),
          SceneTags.brief(engine, _turns, upTo, place: _state.place),
          maxTokens: 1200,
          what: 'Scene tags',
          exact: true,
        );
        prompt = reply == null
            ? ''
            : SceneTags.prompt(reply, engine.world.cast.values);
      } on Object catch (e) {
        services.log.add(LogKind.errors, 'Scene tags failed: $e');
        prompt = '';
      }
      messenger?.hideCurrentSnackBar();
      if (!mounted) return;
      if (prompt.isEmpty) {
        _say('The model gave no tags; write what to draw yourself.');
      }
      final kept = await showDialog<File>(
        context: context,
        builder: (_) => VocesDrawDialog(
          prompt: prompt,
          wide: true,
          folder: library.drawingFolder,
        ),
      );
      if (kept != null) {
        final dir = Directory(p.join(engine.world.folder, 'pictures'));
        await dir.create(recursive: true);
        final to = File(
          p.join(
            dir.path,
            'scene-${DateTime.now().millisecondsSinceEpoch}'
            '${p.extension(kept.path)}',
          ),
        );
        await kept.copy(to.path);
        await PictureInfo.move(kept, to);
        await kept.delete().then((_) {}, onError: (_) {});
        if (mounted) {
          await _add(
            TurnKind.picture,
            p.relative(to.path, from: engine.world.folder),
          );
        }
      }
    } finally {
      // Drawing let the chat model go; have it ready for the next turn.
      services.runtime.ensureReady(services.settings.value).ignore();
      if (mounted) setState(() => _drawing = false);
    }
  }

  /// A new story that goes on from [at]: everything up to it copied, this
  /// story left as it is. The copy opens in its place.
  Future<void> _branch(StoryTurn at) async {
    if (_busy) return;
    final title = await _askTitle('${_story.title} (branch)');
    if (title == null || !mounted) return;
    final services = _services;
    final host = context.getInheritedWidgetOfExactType<VocesEditorHost>();
    final copy = await library.branchStory(_story, title: title);
    final log = await services.openStoryLog(copy.id);
    try {
      final upTo = [
        for (final t in _turns)
          if (t.id >= 0 && t.id <= at.id) t,
      ];
      for (final t in upTo) {
        await log.add(
          t.kind,
          t.text,
          speakerId: t.speakerId,
          speaker: t.speaker,
          now: t.ts,
        );
      }
      await log.setState('story', _state.toJson());
      final saved = await library.saveStory(
        copy.copyWith(turns: upTo.where((t) => !t.kind.aside).length),
      );
      await widget.data.reload();
      if (!mounted) return;
      if (host == null) {
        _say('"${saved.title}" is with your stories.');
        return;
      }
      widget.done(null);
      unawaited(
        host.open<void>(
          (done) => StoryView(data: widget.data, story: saved, done: done),
        ),
      );
    } finally {
      await log.close();
    }
  }

  Future<String?> _askTitle(String start) {
    final c = TextEditingController(text: start);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Branch from here'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A new story goes on from this turn, with everything up to '
                'it. This one stays as it is.',
                style: TextStyle(color: context.palette.textMuted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Its title'),
                onSubmitted: (v) =>
                    Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              c.text.trim().isEmpty ? null : c.text.trim(),
            ),
            child: const Text('Branch'),
          ),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  /// The story as one HTML page with its pictures inside, or as Markdown
  /// with its pictures in a folder beside it.
  Future<void> _export() async {
    final engine = _engine;
    if (engine == null) return;
    final safe = _story.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final at = await getSaveLocation(
      suggestedName: '${safe.isEmpty ? 'story' : safe}.html',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Web page (pictures inside)', extensions: ['html']),
        XTypeGroup(label: 'Markdown', extensions: ['md']),
      ],
    );
    if (at == null || !mounted) return;
    final turns = [
      for (final t in _turns)
        if (t.id >= 0) t,
    ];
    try {
      final md =
          at.activeFilter?.label == 'Markdown' ||
          at.path.toLowerCase().endsWith('.md');
      if (md) {
        final path = at.path.toLowerCase().endsWith('.md')
            ? at.path
            : '${p.withoutExtension(at.path)}.md';
        final pictures = '${p.basenameWithoutExtension(path)} pictures';
        final shots = turns.where((t) => t.kind == TurnKind.picture).toList();
        for (final t in shots) {
          final f = File(p.join(engine.world.folder, t.text));
          if (!await f.exists()) continue;
          final to = File(
            p.join(p.dirname(path), pictures, p.basename(f.path)),
          );
          await to.parent.create(recursive: true);
          await f.copy(to.path);
        }
        await File(path).writeAsString(
          StoryExport.markdown(
            title: _story.title,
            worldName: _story.worldName,
            player: engine.playerName,
            turns: turns,
            pictures: Uri.encodeComponent(pictures),
          ),
        );
      } else {
        final path = at.path.toLowerCase().endsWith('.html')
            ? at.path
            : '${p.withoutExtension(at.path)}.html';
        await File(path).writeAsString(
          await StoryExport.html(
            title: _story.title,
            worldName: _story.worldName,
            player: engine.playerName,
            turns: turns,
            folder: engine.world.folder,
          ),
        );
      }
      _say('Story exported.');
    } on Object catch (e) {
      _say('The story couldn\'t be saved there: $e');
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));

  /// Takes what changed in the world since the story began, the parts the
  /// human picks, into the story's own copy.
  Future<void> _updateFromWorld() async {
    if (_busy) {
      _say('Wait for the reply to finish, then update.');
      return;
    }
    final update = await library.worldUpdate(_story);
    if (!mounted) return;
    if (update == null) {
      _say(
        '"${_story.worldName}" is no longer in your worlds, so there is '
        'nothing to update from.',
      );
      return;
    }
    if (update.isEmpty) {
      _say('Nothing changed in "${_story.worldName}" since this story began.');
      return;
    }
    final pick = await showWorldUpdate(
      context,
      worldName: update.world?.name ?? _story.worldName,
      update: update,
    );
    if (pick == null || !mounted) return;
    final saved = await library.applyWorldUpdate(
      _story,
      update,
      world: pick.world,
      lorebooks: pick.lorebooks,
      cast: pick.cast,
    );
    final world = await library.storyWorld(saved);
    if (!mounted) return;
    setState(() {
      _story = saved;
      _engine = StoryEngine(
        world,
        mature: _services.settings.value.vocesMature,
      );
    });
    _say('Updated. The story uses the new world from the next turn.');
  }

  Future<void> _delete() async {
    final ok = await confirmDelete(
      context,
      title: 'Delete "${_story.title}"?',
      body: 'The whole story goes, for good. The world and characters stay.',
    );
    if (!ok || !mounted) return;
    final services = _services;
    _stop();
    await _log?.close();
    _log = null;
    await services.deleteStoryLog(_story.id);
    await library.deleteStory(_story.id);
    widget.done(null);
  }

  Future<void> _bringIn(VocesCharacter c) async {
    if (_state.present.contains(c.id)) return;
    await _saveState(_state.copyWith(present: [..._state.present, c.id]));
    await _add(TurnKind.scene, '${c.name} arrives', speakerId: c.id);
  }

  Future<void> _sendAway(String id) async {
    final c = _engine!.world.cast[id];
    await _saveState(
      _state.copyWith(
        present: [..._state.present]..remove(id),
        pinned: {..._state.pinned}..remove(id),
      ),
    );
    if (_answerer == id) _answererSet = false;
    if (c != null) {
      await _add(TurnKind.scene, '${c.name} leaves', speakerId: id);
      _toStow.add(id);
      unawaited(_tendCast());
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This story couldn\'t be opened.',
                style: TextStyle(fontSize: 16, color: palette.text),
              ),
              const SizedBox(height: 8),
              Text(
                _short(_error!),
                style: TextStyle(color: palette.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => widget.done(null),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    }
    final engine = _engine;
    if (engine == null) return const Center(child: CircularProgressIndicator());
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_busy) _stop();
        },
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final side = wide || _sideOpen;
          return Column(
            children: [
              _header(context, engine, wide: wide),
              Divider(height: 1, color: palette.glassBorder),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          if (_backdrop(engine) case final file?)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: _Backdrop(
                                  file: file,
                                  background: palette.background,
                                ),
                              ),
                            ),
                          Column(
                            children: [
                              Expanded(child: _storyList(context, engine)),
                              if (_recap != null || _recapping)
                                _recapCard(context),
                              _composer(context, engine),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (side) ...[
                      VerticalDivider(width: 1, color: palette.glassBorder),
                      SizedBox(
                        width: 250,
                        child: _StorySide(
                          engine: engine,
                          state: _state,
                          busy: _busy,
                          onState: _saveState,
                          onBringIn: _bringIn,
                          onSendAway: _sendAway,
                          onSave: _saveToCharacters,
                          onKeep: _busy ? null : _promote,
                          writing: _sheets,
                          notesBusy: _notesBusy,
                          onEditNotes: _editNotes,
                          onUpdateNotes: _busy || _notesBusy
                              ? null
                              : () => _keepNotes(force: true),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, StoryEngine engine, {bool wide = true}) {
    final palette = context.palette;
    final world = engine.world;
    final narrow = MediaQuery.sizeOf(context).width < 1200;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to the worlds',
            onPressed: () => widget.done(null),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 6),
          VocesAvatar(
            name: world.world.name,
            seed: world.world.art,
            file: world.picture,
            size: 38,
            radius: 10,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _story.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: palette.text,
                  ),
                ),
                Text(
                  [
                    world.world.name,
                    'as ${engine.playerName}',
                    _story.difficulty.label,
                    if (_state.place.isNotEmpty && narrow) _state.place,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ],
            ),
          ),
          if (!wide)
            IconButton(
              tooltip: _sideOpen ? 'Hide who\'s here' : 'Who\'s here',
              isSelected: _sideOpen,
              onPressed: () => setState(() => _sideOpen = !_sideOpen),
              icon: const Icon(Icons.groups_rounded),
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) {
              if (v == 'update') _updateFromWorld();
              if (v == 'recap') _makeRecap();
              if (v == 'export') _export();
              if (v == 'branch' && _turns.isNotEmpty) _branch(_turns.last);
              if (v == 'backdrop') {
                final s = _services.settings;
                s.update(
                  s.value.copyWith(vocesBackdrop: !s.value.vocesBackdrop),
                );
              }
              if (v == 'draw') {
                final last = _turns.lastWhere(
                  (t) => !t.kind.aside,
                  orElse: () => _turns.last,
                );
                _drawScene(last);
              }
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'recap',
                enabled: !_busy && !_recapping && _turns.isNotEmpty,
                child: const Text('Previously on…'),
              ),
              CheckedPopupMenuItem(
                value: 'backdrop',
                checked: _services.settings.value.vocesBackdrop,
                child: const Text('Picture behind the story'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'draw',
                enabled: !_busy && !_drawing && _turns.isNotEmpty,
                child: const Text('Draw the scene'),
              ),
              PopupMenuItem(
                value: 'branch',
                enabled: !_busy && _turns.isNotEmpty,
                child: const Text('Branch from here'),
              ),
              PopupMenuItem(
                value: 'export',
                enabled: _turns.isNotEmpty,
                child: const Text('Export story…'),
              ),
              const PopupMenuItem(
                value: 'update',
                child: Text('Update from the world'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete story')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _storyList(BuildContext context, StoryEngine engine) {
    final palette = context.palette;
    final writing = _busy && _writing.isNotEmpty;
    final items = [
      for (final t in _turns) t,
      if (writing)
        StoryTurn(
          id: -1,
          kind: _writer == null ? TurnKind.narrator : TurnKind.character,
          speakerId: _writer,
          speaker: engine.nameOf(_writer),
          text: _writer == null
              ? StoryEngine.splitPlace(_writing.toString()).text
              : engine.clean(_writing.toString(), _writer),
          ts: DateTime.now(),
        ),
    ];
    final lastAi = _turns.lastOrNull;
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
        itemCount: items.length + 1,
        itemBuilder: (context, i) {
          if (i == items.length) {
            return _busy && !writing
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      '${engine.nameOf(_writer)} is thinking…',
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: palette.textMuted,
                      ),
                    ),
                  )
                : const SizedBox(height: 8);
          }
          final t = items[i];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _TurnTile(
                key: ValueKey(t.id),
                turn: t,
                engine: engine,
                live: t.id == -1,
                onEdit: t.id < 0 || _busy || t.kind == TurnKind.picture
                    ? null
                    : () => _edit(t),
                onDraw: t.id < 0 || _busy || _drawing || t.kind.aside
                    ? null
                    : () => _drawScene(t),
                onBranch: t.id < 0 || _busy ? null : () => _branch(t),
                roll: _state.rolls[t.id],
                onRewind: t.id < 0 || _busy ? null : () => _rewind(t),
                onRetry:
                    !_busy &&
                        t.id == lastAi?.id &&
                        !t.kind.byHuman &&
                        !t.kind.aside
                    ? _retry
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _composer(BuildContext context, StoryEngine engine) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final names = {for (final id in _state.present) id: engine.nameOf(id)};
    final who = !_answererSet
        ? 'Answers: the story decides'
        : 'Answers: ${engine.nameOf(_answerer)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final m in _Mode.values)
                    VocesPill(
                      m.label,
                      on: _mode == m,
                      onTap: () {
                        setState(() => _mode = m);
                        _inputFocus.requestFocus();
                      },
                    ),
                  if (_mode == _Mode.play) ...[
                    const SizedBox(width: 4),
                    _markButton('"', 'Speech: "words in quotes"'),
                    _markButton('*', 'Action: *in asterisks*'),
                    IconButton(
                      tooltip: _rollNext
                          ? 'This turn gets a roll'
                          : 'Roll for this turn: a lie, a sneak, a leap'
                                '${_story.difficulty == Difficulty.punishing || _story.difficulty == Difficulty.grimdark ? ' (actions roll on their own here)' : ''}',
                      isSelected: _rollNext,
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => setState(() => _rollNext = !_rollNext),
                      icon: const Icon(Icons.casino_outlined),
                      selectedIcon: const Icon(Icons.casino_rounded),
                    ),
                  ],
                  const SizedBox(width: 10),
                  if (_busy && _state.chain > 0)
                    VocesPill(
                      _jumpIn ? 'Your turn next' : 'Jump in',
                      on: _jumpIn,
                      onTap: () => setState(() => _jumpIn = true),
                    ),
                  PopupMenuButton<String?>(
                    tooltip: 'Who answers next',
                    onSelected: (id) => setState(() {
                      _answererSet = id != '*';
                      _answerer = id == '*' || id == '' ? null : id;
                    }),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: '*',
                        child: Text('The story decides'),
                      ),
                      const PopupMenuItem(value: '', child: Text('Narrator')),
                      for (final e in names.entries)
                        PopupMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        who,
                        style: TextStyle(
                          fontSize: 12,
                          color: _answererSet ? accent : palette.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Theme(
                data: editorTheme(context),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): _send,
                  },
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 6,
                    onChanged: (_) {
                      // Typing while others talk: the human is next.
                      if (_busy && !_jumpIn) setState(() => _jumpIn = true);
                    },
                    decoration: InputDecoration(
                      hintText: _mode.hint,
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_busy)
                            IconButton(
                              tooltip: 'Stop (Esc)',
                              onPressed: _stop,
                              icon: const Icon(Icons.stop_rounded),
                            )
                          else ...[
                            IconButton(
                              tooltip: 'Continue: let the story go on',
                              onPressed: _continue,
                              icon: const Icon(Icons.fast_forward_rounded),
                            ),
                            IconButton(
                              tooltip: 'Send (Enter)',
                              onPressed: _send,
                              icon: Icon(Icons.send_rounded, color: accent),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One turn: narrator prose, a character's bubble, the human's line, or a
/// divider when someone comes or goes.
class _TurnTile extends StatefulWidget {
  const _TurnTile({
    super.key,
    required this.turn,
    required this.engine,
    required this.live,
    this.onEdit,
    this.onRewind,
    this.onRetry,
    this.onDraw,
    this.onBranch,
    this.roll,
  });

  final StoryTurn turn;
  final StoryEngine engine;
  final bool live;
  final VoidCallback? onDraw;
  final VoidCallback? onBranch;

  /// The roll this turn got, if any.
  final int? roll;
  final VoidCallback? onEdit;
  final VoidCallback? onRewind;
  final VoidCallback? onRetry;

  @override
  State<_TurnTile> createState() => _TurnTileState();
}

class _TurnTileState extends State<_TurnTile> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.turn;
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    if (t.kind == TurnKind.scene) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(child: Divider(color: palette.glassBorder)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                t.text,
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.4,
                  color: palette.textMuted,
                ),
              ),
            ),
            Expanded(child: Divider(color: palette.glassBorder)),
          ],
        ),
      );
    }
    final base = TextStyle(fontSize: 15, height: 1.55, color: palette.text);
    final Widget body;
    switch (t.kind) {
      case TurnKind.picture:
        final file = File(p.join(widget.engine.world.folder, t.text));
        body = Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: () => _open(file),
            child: MouseRegion(
              cursor: SystemMouseCursors.zoomIn,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Container(
                      padding: const EdgeInsets.all(14),
                      color: palette.tile,
                      child: Text(
                        'This picture is missing.',
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      case TurnKind.narrator:
        body = Text.rich(
          storyText(
            StoryEngine.splitPlace(t.text).text,
            base.copyWith(fontSize: 15.5),
            palette.textMuted,
          ),
        );
      case TurnKind.character:
        final c = widget.engine.world.cast[t.speakerId];
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VocesAvatar(
              name: t.speaker,
              seed: c?.art,
              file: c == null ? null : widget.engine.world.portraitOf(c),
              size: 34,
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  color: palette.bubble,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: palette.glassBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.speaker,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text.rich(storyText(t.text, base, palette.textMuted)),
                  ],
                ),
              ),
            ),
          ],
        );
      default:
        final label = switch (t.kind) {
          TurnKind.act => '${widget.engine.playerName} does',
          TurnKind.ask => 'You ask the narrator',
          _ => widget.engine.playerName,
        };
        body = Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette.textMuted,
                  ),
                ),
                const SizedBox(height: 3),
                if (widget.roll case final n?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Tooltip(
                      message: 'Rolled $n of 20: ${Fortune.outcome(n)}.',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.tile,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.casino_rounded,
                              size: 13,
                              color: n <= 5
                                  ? Colors.redAccent
                                  : n >= 16
                                  ? Colors.greenAccent
                                  : palette.textMuted,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '$n · ${Fortune.outcome(n)}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: palette.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (t.kind == TurnKind.say)
                  Text.rich(storyText(t.text, base, palette.textMuted))
                else
                  Text(
                    t.text,
                    style: base.copyWith(fontStyle: FontStyle.italic),
                  ),
              ],
            ),
          ),
        );
    }
    final tools = !_hover || widget.live
        ? const SizedBox(height: 26)
        : SizedBox(
            height: 26,
            child: Row(
              mainAxisAlignment: t.kind.byHuman
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (widget.onRetry != null)
                  _tool(
                    Icons.refresh_rounded,
                    'Write it again',
                    widget.onRetry,
                  ),
                if (widget.onDraw != null)
                  _tool(Icons.brush_rounded, 'Draw this', widget.onDraw),
                if (widget.onEdit != null)
                  _tool(Icons.edit_rounded, 'Edit', widget.onEdit),
                if (widget.onBranch != null)
                  _tool(
                    Icons.call_split_rounded,
                    'Branch from here',
                    widget.onBranch,
                  ),
                if (widget.onRewind != null)
                  _tool(Icons.undo_rounded, 'Go back to here', widget.onRewind),
              ],
            ),
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [body, tools],
        ),
      ),
    );
  }

  /// The picture, big, over the story; a click closes it.
  void _open(File file) => showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => GestureDetector(
      onTap: () => Navigator.pop(context),
      child: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.file(file)),
      ),
    ),
  );

  Widget _tool(IconData icon, String tip, VoidCallback? onTap) => IconButton(
    tooltip: tip,
    onPressed: onTap,
    iconSize: 15,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 28, height: 26),
    icon: Icon(icon),
  );
}

/// [text] with *actions* in italics.
/// [value] with [mark] around the selected words, or a pair of marks at
/// the cursor with the cursor between them.
TextEditingValue wrapWithMark(TextEditingValue value, String mark) {
  final text = value.text;
  var sel = value.selection;
  if (!sel.isValid) {
    sel = TextSelection.collapsed(offset: text.length);
  }
  final before = text.substring(0, sel.start);
  final picked = text.substring(sel.start, sel.end);
  final after = text.substring(sel.end);
  // A space before the pair when it follows a word.
  final gap = before.isNotEmpty && !before.endsWith(' ') && picked.isEmpty
      ? ' '
      : '';
  final wrapped = '$gap$mark$picked$mark';
  return TextEditingValue(
    text: '$before$wrapped$after',
    selection: TextSelection.collapsed(
      offset: picked.isEmpty
          ? before.length + gap.length + 1
          : before.length + wrapped.length,
    ),
  );
}

/// Who's here, where, and how the story runs.
class _StorySide extends StatelessWidget {
  const _StorySide({
    required this.engine,
    required this.state,
    required this.busy,
    required this.onState,
    required this.onBringIn,
    required this.onSendAway,
    required this.onSave,
    required this.onKeep,
    required this.writing,
    required this.notesBusy,
    required this.onEditNotes,
    required this.onUpdateNotes,
  });

  final bool notesBusy;
  final VoidCallback onEditNotes;
  final VoidCallback? onUpdateNotes;
  final StoryEngine engine;
  final StoryState state;
  final bool busy;
  final ValueChanged<StoryState> onState;
  final ValueChanged<VocesCharacter> onBringIn;
  final ValueChanged<String> onSendAway;
  final ValueChanged<String> onSave;

  /// Gives an extra a sheet now; null while a reply is written.
  final ValueChanged<Extra>? onKeep;

  /// Extras whose sheet is being written.
  final Set<String> writing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    final away = [
      for (final c in engine.voices)
        if (!state.present.contains(c.id)) c,
    ];
    final player = engine.player;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      children: [
        if (state.place.isNotEmpty) ...[
          const VocesLabel('Where'),
          const SizedBox(height: 6),
          Text(state.place, style: TextStyle(color: palette.text)),
          const SizedBox(height: 18),
        ],
        const VocesLabel('Here'),
        const SizedBox(height: 8),
        if (player != null) _person(context, player, you: true),
        for (final id in state.present)
          if (engine.world.cast[id] != null)
            _person(
              context,
              engine.world.cast[id]!,
              pinned: state.pinned.contains(id),
              onPin: () => onState(
                state.copyWith(
                  pinned: state.pinned.contains(id)
                      ? ({...state.pinned}..remove(id))
                      : {...state.pinned, id},
                ),
              ),
              onAway: busy ? null : () => onSendAway(id),
              onSave: () => onSave(id),
            ),
        if (state.present.isEmpty) Text('Only you, for now.', style: muted),
        if (away.isNotEmpty) ...[
          const SizedBox(height: 6),
          PopupMenuButton<VocesCharacter>(
            enabled: !busy,
            tooltip: 'Bring someone in',
            onSelected: onBringIn,
            itemBuilder: (_) => [
              for (final c in away)
                PopupMenuItem(value: c, child: Text(c.name)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.person_add_alt_rounded, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Bring someone in',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (state.extras.isNotEmpty) ...[
          const SizedBox(height: 20),
          const VocesLabel('Met along the way'),
          const SizedBox(height: 6),
          for (final e in state.extras)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: e.line,
                      child: Text(
                        e.line.isEmpty ? e.name : '${e.name} · ${e.line}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: palette.text),
                      ),
                    ),
                  ),
                  if (writing.contains(e.name))
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip:
                          'Keep them: write a sheet, and they speak for '
                          'themselves',
                      onPressed: onKeep == null ? null : () => onKeep!(e),
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.person_add_alt_1_outlined),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'People the narrator brought in. Those who keep coming up, or '
            'whom you talk to, get a sheet of their own.',
            style: muted,
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: VocesLabel('Notes')),
            if (notesBusy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Update the notes from the story now',
                onPressed: onUpdateNotes,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.sync_rounded),
              ),
            IconButton(
              tooltip: 'Edit the notes',
              onPressed: onEditNotes,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_note_rounded),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (state.notes.isEmpty)
          Text(
            'What you carry, what is still to do and how people feel about '
            'you. The narrator fills these in every few turns.',
            style: muted,
          )
        else ...[
          for (final (label, lines) in [
            ('Carrying', state.notes.items),
            ('Still to do', state.notes.quests),
            (
              'How people feel',
              [
                for (final e in state.notes.feelings.entries)
                  '${e.key}: ${e.value}',
              ],
            ),
          ])
            if (lines.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(label, style: muted),
              ),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                  child: Text(
                    '• $l',
                    style: TextStyle(fontSize: 12.5, color: palette.text),
                  ),
                ),
            ],
        ],
        const SizedBox(height: 20),
        const VocesLabel('Comings and goings'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in Liveliness.values)
              VocesPill(
                l.label,
                on: state.liveliness == l,
                onTap: () => onState(state.copyWith(liveliness: l)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'How often people turn up or leave on their own. A pin keeps '
          'someone here.',
          style: muted,
        ),
        const SizedBox(height: 20),
        const VocesLabel('Replies in a row'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var n = 0; n <= StoryState.maxChain; n++)
              VocesPill(
                n == 0 ? 'Off' : '$n',
                on: state.chain == n,
                onTap: () => onState(state.copyWith(chain: n)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'How many others may answer each other before it\'s your turn. '
          'They stop when someone turns to you.',
          style: muted,
        ),
      ],
    );
  }

  Widget _person(
    BuildContext context,
    VocesCharacter c, {
    bool you = false,
    bool pinned = false,
    VoidCallback? onPin,
    VoidCallback? onAway,
    VoidCallback? onSave,
  }) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          VocesAvatar(
            name: c.name,
            seed: c.art,
            file: engine.world.portraitOf(c),
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              you ? '${c.name} (you)' : c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: palette.text),
            ),
          ),
          if (onPin != null)
            IconButton(
              tooltip: pinned ? 'Pinned: stays here' : 'Pin: keep them here',
              onPressed: onPin,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                color: pinned ? accent : palette.textMuted,
              ),
            ),
          if (onSave != null)
            PopupMenuButton<VoidCallback>(
              tooltip: 'More about ${c.name}',
              iconSize: 16,
              icon: Icon(Icons.more_vert_rounded, color: palette.textMuted),
              onSelected: (f) => f(),
              itemBuilder: (_) => [
                if (onAway != null)
                  PopupMenuItem(
                    value: onAway,
                    child: const Text('Send them off'),
                  ),
                PopupMenuItem(
                  value: onSave,
                  child: const Text('Save to Characters'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A picture behind the story, dimmed and softened so the turns stay easy
/// to read.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.file, required this.background});

  final File file;
  final Color background;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 600),
    child: Stack(
      key: ValueKey(file.path),
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
          child: Opacity(
            opacity: 0.22,
            child: Image.file(
              file,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                background.withValues(alpha: 0.1),
                background.withValues(alpha: 0.55),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
