import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../data/voces/story_log.dart';
import '../../services/logs/app_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/voces/describer.dart';
import '../../services/voces/living_cast.dart';
import '../../services/voces/story_engine.dart';
import '../../theme/app_theme.dart';
import 'voces_editor.dart';
import 'voces_home.dart';
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
                DropdownButtonFormField<String>(
                  initialValue: _player?.id,
                  isExpanded: true,
                  items: [
                    for (final c in widget.data.characters)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          c.line.isEmpty ? c.name : '${c.name} · ${c.line}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) =>
                      _pick(id == null ? null : widget.data.character(id)),
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
  say('Say', TurnKind.say, 'What do you say?'),
  act('Do', TurnKind.act, 'What do you do?'),
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
  var _mode = _Mode.say;

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
    if (_state.extras.isNotEmpty && kind != TurnKind.scene) {
      unawaited(
        _saveState(
          _state.copyWith(extras: LivingCast.count(_state.extras, turn)),
        ),
      );
    }
    _story = _story.copyWith(
      lastPlayed: DateTime.now(),
      turns: _turns.where((t) => t.kind != TurnKind.scene).length,
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

  /// The human's line, then whoever answers, and the chain after.
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    final engine = _engine!;
    final before = _turns;
    final turn = await _add(_mode.kind, text);
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
      }
    }
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
        CharacterDescriber.instructions,
        CharacterDescriber.brief(LivingCast.sheetIdea(e, moments)),
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
    if (last.kind == TurnKind.scene) return;
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
                      child: Column(
                        children: [
                          Expanded(child: _storyList(context, engine)),
                          _composer(context, engine),
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
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Delete story')),
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
                onEdit: t.id < 0 || _busy ? null : () => _edit(t),
                onRewind: t.id < 0 || _busy ? null : () => _rewind(t),
                onRetry:
                    !_busy &&
                        t.id == lastAi?.id &&
                        !t.kind.byHuman &&
                        t.kind != TurnKind.scene
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
  });

  final StoryTurn turn;
  final StoryEngine engine;
  final bool live;
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
      case TurnKind.narrator:
        body = Text.rich(
          _styled(
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
                    Text.rich(_styled(t.text, base, palette.textMuted)),
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
                Text(
                  t.text,
                  style: t.kind == TurnKind.say
                      ? base
                      : base.copyWith(fontStyle: FontStyle.italic),
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
                if (widget.onEdit != null)
                  _tool(Icons.edit_rounded, 'Edit', widget.onEdit),
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
TextSpan _styled(String text, TextStyle base, Color muted) {
  final spans = <TextSpan>[];
  final re = RegExp(r'\*([^*\n]+)\*');
  var at = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(
      TextSpan(
        text: m.group(1),
        style: TextStyle(fontStyle: FontStyle.italic, color: muted),
      ),
    );
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: base, children: spans);
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
  });

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
