import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../data/voces/story_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../images/image_catalog.dart';
import '../images/image_engine.dart';
import '../images/picture_info.dart';
import '../images/sd_runtime.dart';
import '../logs/app_log.dart';
import 'chat_import.dart';
import 'describer.dart';
import 'living_cast.dart';
import 'scene_tags.dart';
import 'story_engine.dart';
import 'story_notes.dart';

/// One story being played: its turns, who is here, and the replies being
/// written. Kept apart from the screen, so the window and a phone can play
/// the same story at once and both see every turn as it is written
/// ([AppServices.openStory]).
class StorySession extends ChangeNotifier {
  StorySession(this._services, this.library, this.story, {List<String>? cast})
    : _cast = cast;

  final AppServices _services;
  final VocesLibrary library;
  final List<String>? _cast;

  StorySave story;
  StoryLog? _log;
  StoryEngine? engine;
  List<StoryTurn> turns = const [];
  StoryState state = const StoryState();

  /// Why the story couldn't be opened.
  Object? error;

  /// A reply is being written, by [writer] (null: the narrator).
  bool busy = false;
  String? writer;
  final writing = StringBuffer();

  bool notesBusy = false;

  /// Extras whose sheet is being written.
  final sheets = <String>{};

  /// A picture of the scene is being made.
  bool drawing = false;

  /// "Previously on…", shown until closed; [recapping] while it is
  /// written.
  String? recap;
  bool recapping = false;

  /// Things to tell whoever is playing: a snackbar in the window, a note
  /// on the phone.
  Stream<String> get notices => _notices.stream;
  final _notices = StreamController<String>.broadcast();

  /// How many screens have this story open; it closes with the last.
  int users = 0;

  /// Narration since the cast was last tended, people to stow.
  final _newNarration = <String>[];
  final _toStow = <String>{};
  var _tending = false;
  StreamSubscription<String>? _stream;
  Completer<bool>? _streamDone;
  var _jumpIn = false;
  bool _closed = false;
  bool get closed => _closed;

  /// When each story last opened with a recap since VoxCordis started.
  static final _recappedAt = <String, DateTime>{};

  /// Streamed words are passed on at most this often.
  static const _frame = Duration(milliseconds: 50);
  Timer? _frameTimer;

  void _changed() {
    if (_closed) return;
    _frameTimer?.cancel();
    _frameTimer = null;
    notifyListeners();
  }

  void _changedSoon() {
    if (_closed) return;
    _frameTimer ??= Timer(_frame, () {
      _frameTimer = null;
      if (!_closed) notifyListeners();
    });
  }

  void say(String text) {
    if (!_closed) _notices.add(text);
  }

  void _note(String what, Object e) =>
      _services.log.add(LogKind.errors, what, details: '$e', error: true);

  /// Opens the story's turns; a story not played yet gets its opening.
  Future<void> open() async {
    try {
      final world = await library.storyWorld(story);
      final log = await _services.openStoryLog(story.id);
      if (_closed) {
        await log.close();
        return;
      }
      final e = StoryEngine(
        world,
        mature: _services.settings.value.vocesMature,
      );
      final saved = (await log.state())['story'];
      final list = await log.turns();
      final StoryState s;
      if (saved is Map) {
        s = StoryState.fromJson(saved.cast<String, Object?>());
      } else {
        s = StoryState(present: e.startingCast(_cast));
        await log.setState('story', s.toJson());
      }
      _log = log;
      engine = e;
      state = s;
      turns = list;
      _changed();
      final now = DateTime.now();
      if (StoryEngine.wantsRecap(list, now, lastRecap: _recappedAt[story.id])) {
        _recappedAt[story.id] = now;
        unawaited(makeRecap());
      }
      unawaited(_catchUpImported());
      if (list.isEmpty) {
        final opening = world.world.openings
            .where((o) => o.title == story.opening)
            .firstOrNull;
        if (opening != null && opening.text.trim().isNotEmpty) {
          final split = StoryEngine.splitPlace(opening.text);
          if (split.place != null) await _setPlace(split.place!);
          await add(TurnKind.narrator, split.text);
        } else {
          await run(null, chain: false);
        }
      }
    } on Object catch (e) {
      error = e;
      _changed();
    }
  }

  /// Stops what is being written and closes the turns.
  Future<void> close() async {
    if (_closed) return;
    stop();
    _closed = true;
    _frameTimer?.cancel();
    await _notices.close();
    await _log?.close();
    _log = null;
    super.dispose();
  }

  Future<void> saveState(StoryState s) async {
    state = s;
    _changed();
    await _log?.setState('story', s.toJson());
  }

  Future<void> _setPlace(String place) =>
      saveState(state.copyWith(place: place));

  Future<StoryTurn> add(
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
    if (_closed) return turn;
    turns = [...turns, turn];
    _changed();
    if (state.extras.isNotEmpty && !kind.aside) {
      unawaited(
        saveState(state.copyWith(extras: LivingCast.count(state.extras, turn))),
      );
    }
    story = story.copyWith(
      lastPlayed: DateTime.now(),
      turns: turns.where((t) => !t.kind.aside).length,
      place: state.place,
    );
    unawaited(library.saveStory(story));
    return turn;
  }

  /// The human's line, then whoever answers, and the chain after.
  /// [answerer] is whoever the human picked to answer, when [picked];
  /// otherwise the story decides. [roll] gives the turn a roll.
  Future<void> send(
    TurnKind kind,
    String text, {
    bool roll = false,
    bool picked = false,
    String? answerer,
  }) async {
    text = text.trim();
    final e = engine;
    if (text.isEmpty || busy || e == null || !kind.byHuman) return;
    final before = turns;
    final turn = await add(kind, text);
    if (roll || Fortune.rollsOnItsOwn(turn, story.difficulty)) {
      await saveState(
        state.copyWith(rolls: {...state.rolls, turn.id: Fortune.roll()}),
      );
    }
    final who = picked ? answerer : e.whoAnswers(turn, before, state);
    await run(who);
  }

  /// "Continue": the story goes on without the human.
  Future<void> continueStory({bool picked = false, String? answerer}) async {
    final e = engine;
    if (busy || e == null) return;
    final who = picked ? answerer : e.whoContinues(turns, state);
    await run(who);
  }

  /// Writes [first]'s reply, then lets those it names answer, up to the
  /// chain's length or until the human jumps in.
  Future<void> run(String? first, {bool chain = true}) async {
    busy = true;
    _jumpIn = false;
    _changed();
    try {
      String? speaker = first;
      var left = chain ? state.chain : 0;
      while (!_closed) {
        final reply = await _reply(speaker);
        if (reply == null || _jumpIn || left-- <= 0) break;
        final next = engine!.chainsTo(reply, speaker, state);
        if (next == null) break;
        speaker = next;
      }
    } finally {
      if (!_closed) {
        busy = false;
        writer = null;
        _changed();
        unawaited(_tendCast());
        unawaited(keepNotes());
      }
    }
  }

  /// The human started typing while others answer each other: the chain
  /// stops after the reply being written.
  void jumpIn() {
    if (!busy || _jumpIn) return;
    _jumpIn = true;
    _changed();
  }

  bool get jumpedIn => _jumpIn;

  /// Brings the story notes up to date every [StoryNotes.every] told
  /// turns, or now when [force]. Waits for replies; uses the chat model.
  Future<void> keepNotes({bool force = false}) async {
    final e = engine;
    if (e == null || notesBusy || busy || _closed) return;
    final fresh = [
      for (final t in turns)
        if (t.id > state.notesAt && t.id >= 0 && !t.kind.aside) t,
    ];
    if (fresh.isEmpty || (!force && fresh.length < StoryNotes.every)) return;
    notesBusy = true;
    _changed();
    try {
      // A long stretch (a chat brought in from Soulkyn) a part at a time;
      // each part done is kept, so a stop picks up where it was.
      final parts = StoryEngine.parts(fresh);
      for (final (i, part) in parts.indexed) {
        if (_closed || (i > 0 && busy)) break;
        final reply = await _services.models.ask(
          StoryNotes.instructions(e.playerName),
          StoryNotes.brief(state.notes, e.playerName, e.transcript(part)),
          maxTokens: 900,
          what: parts.length == 1
              ? 'Story notes'
              : 'Story notes, part ${i + 1} of ${parts.length}',
          exact: true,
        );
        final notes = StoryNotes.parse(reply);
        if (notes != null && !_closed) {
          await saveState(state.copyWith(notes: notes, notesAt: part.last.id));
        } else {
          if (force && !_closed) {
            say('The notes couldn\'t be updated this time.');
          }
          break;
        }
      }
    } on Object catch (err) {
      _services.log.add(LogKind.errors, 'Story notes failed: $err');
    } finally {
      notesBusy = false;
      _changed();
    }
  }

  /// A story brought in from a Soulkyn chat: finds the people of the old
  /// chat and fills the notes, a part at a time, between replies. Where it
  /// got to is kept, so it goes on the next time the story opens.
  Future<void> _catchUpImported() async {
    final log = _log;
    if (log == null || engine == null) return;
    final at = (await log.state())[VocesChatImport.peopleAtKey];
    if (at is! int || _closed) return;
    final told = [
      for (final t in turns)
        if (t.id > at && !t.kind.aside) t,
    ];
    if (told.length > StoryNotes.every) {
      say(
        'This story came from a chat, so Voces Mundi reads it through for '
        'its people and notes. You can play meanwhile.',
      );
    }
    for (final part in StoryEngine.parts(told)) {
      if (_closed || busy) return;
      final narration = [
        for (final t in part)
          if (t.kind == TurnKind.narrator || t.kind == TurnKind.character)
            t.text,
      ].join('\n\n');
      if (narration.isNotEmpty) await _findExtras(narration);
      if (_closed) return;
      var extras = state.extras;
      for (final t in part) {
        extras = LivingCast.count(extras, t);
      }
      await saveState(state.copyWith(extras: extras));
      await log.setState(VocesChatImport.peopleAtKey, part.last.id);
    }
    if (_closed) return;
    // Read through: from here on, people are found as the story goes.
    await log.setState(VocesChatImport.peopleAtKey, null);
    await keepNotes();
    await _tendCast();
  }

  /// Between turns: notices people the narrator named, gives a sheet to
  /// the ones who came up often or were talked to, and notes what those
  /// who left went through. Uses the chat model, so it waits for replies.
  Future<void> _tendCast() async {
    if (_tending || _closed) return;
    _tending = true;
    try {
      while (!_closed && !busy && _newNarration.isNotEmpty) {
        final text = _newNarration.join('\n\n');
        _newNarration.clear();
        await _findExtras(text);
      }
      for (final id in [..._toStow]) {
        if (_closed || busy) break;
        _toStow.remove(id);
        await _stow(id);
      }
      for (final e in [...state.extras]) {
        if (_closed || busy) break;
        if (LivingCast.ripe(e)) await promote(e);
      }
    } finally {
      _tending = false;
    }
  }

  Set<String> get _known => {
    engine!.playerName,
    for (final c in engine!.world.cast.values) c.name,
    for (final e in state.extras) e.name,
  };

  Future<void> _findExtras(String text) async {
    final known = _known;
    if (LivingCast.candidates(text, known).isEmpty) return;
    try {
      final reply = await _services.models.ask(
        LivingCast.finderInstructions,
        LivingCast.finderBrief(text, known.toList()),
        maxTokens: 400,
        what: 'Who is new in the story',
        exact: true,
      );
      if (_closed) return;
      final found = [
        for (final e in LivingCast.parseFound(reply, known))
          if (LivingCast.names(text, e.name)) e,
      ];
      if (found.isEmpty) return;
      await saveState(
        state.copyWith(extras: LivingCast.merge(state.extras, found)),
      );
    } on Object catch (e) {
      _note('Voces Mundi couldn\'t look for new people in the story', e);
    }
  }

  /// Gives extra [e] a sheet written from their moments in the story; from
  /// then on they speak for themselves.
  Future<void> promote(Extra e) async {
    if (!sheets.add(e.name)) return;
    _changed();
    try {
      final en = engine!;
      final moments = LivingCast.excerpts(
        e.name,
        turns,
        playerName: en.playerName,
      );
      final reply = await _services.models.ask(
        CharacterDescriber.instructions(
          adult: en.mature && en.world.world.adult,
        ),
        CharacterDescriber.brief(
          LivingCast.sheetIdea(e, moments),
          adult: en.mature && en.world.world.adult,
        ),
        what: 'A sheet for someone met in the story',
      );
      final d = CharacterDescriber.parse(reply);
      if (d == null || _closed) return;
      final c = await library.saveStoryCharacter(
        story,
        VocesCharacter(
          id: '',
          name: e.name,
          line: d.line.isEmpty ? e.line : d.line,
          pronouns: d.pronouns.isEmpty ? null : d.pronouns,
          tags: d.traits,
          looksTags: d.looksTags,
          sections: d.sections,
          source: 'Met in "${story.title}"',
          created: DateTime.now(),
        ),
      );
      if (_closed) return;
      en.world.cast[c.id] = c;
      final present = state.present.contains(c.id)
          ? state.present
          : [...state.present, c.id];
      await saveState(
        state.copyWith(
          present: present,
          extras: [
            for (final x in state.extras)
              if (x.name != e.name) x,
          ],
        ),
      );
      await add(
        TurnKind.scene,
        '${c.name} now speaks for themselves',
        speakerId: c.id,
      );
    } on Object catch (err) {
      _note('Voces Mundi couldn\'t write a sheet for ${e.name}', err);
    } finally {
      sheets.remove(e.name);
      _changed();
    }
  }

  /// Notes on [id]'s sheet what they went through, so they come back as
  /// they left.
  Future<void> _stow(String id) async {
    final en = engine!;
    final c = en.world.cast[id];
    if (c == null) return;
    final moments = LivingCast.excerpts(
      c.name,
      turns,
      playerName: en.playerName,
    );
    if (moments.isEmpty) return;
    try {
      final reply = await _services.models.ask(
        LivingCast.pastInstructions,
        LivingCast.pastBrief(c.name, moments),
        maxTokens: 400,
        what: 'A character\'s past',
      );
      final past = reply
          .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .trim();
      if (past.isEmpty || _closed) return;
      final saved = await library.saveStoryCharacter(
        story,
        c.copyWith(
          sections: [
            for (final s in c.sections)
              if (s.heading != LivingCast.pastHeading) s,
            SheetSection(LivingCast.pastHeading, past),
          ],
        ),
      );
      en.world.cast[id] = saved;
    } on Object catch (e) {
      _note('Voces Mundi couldn\'t note what ${c.name} went through', e);
    }
  }

  /// Someone of the cast comes into the scene.
  Future<void> bringIn(String id) async {
    final c = engine?.world.cast[id];
    if (c == null || state.present.contains(id)) return;
    await saveState(state.copyWith(present: [...state.present, id]));
    await add(TurnKind.scene, '${c.name} arrives', speakerId: id);
  }

  /// Someone leaves the scene; what they went through is noted on their
  /// sheet.
  Future<void> sendAway(String id) async {
    final c = engine?.world.cast[id];
    await saveState(
      state.copyWith(
        present: [...state.present]..remove(id),
        pinned: {...state.pinned}..remove(id),
      ),
    );
    if (c != null) {
      await add(TurnKind.scene, '${c.name} leaves', speakerId: id);
      _toStow.add(id);
      unawaited(_tendCast());
    }
  }

  /// One reply by [speaker] (null: the narrator); its text once kept,
  /// null when it was stopped or failed.
  Future<String?> _reply(String? speaker) async {
    final en = engine!;
    CastChange? change;
    if (speaker == null) {
      change = en.rollChange(state);
      if (change != null) {
        final present = [...state.present];
        change.arrives
            ? present.add(change.who.id)
            : present.remove(change.who.id);
        await saveState(state.copyWith(present: present));
        await add(TurnKind.scene, change.line, speakerId: change.who.id);
        if (!change.arrives) _toStow.add(change.who.id);
      }
    }
    final prompt = en.prompt(
      speaker,
      turns,
      state,
      change: change,
      byMeaning: await _loreByMeaning(),
    );
    if (_closed) return null;
    writer = speaker;
    writing.clear();
    _changed();
    final finished = Completer<bool>();
    _streamDone = finished;
    Object? failed;
    _stream = _services.models
        .stream(
          prompt.system,
          prompt.user,
          stop: prompt.stop,
          what: speaker == null ? 'A narrator turn' : 'A character turn',
          // The model stopped and was started again: the turn is written
          // from its start.
          again: () {
            writing.clear();
            _changedSoon();
          },
        )
        .listen(
          (piece) {
            if (_closed) return;
            writing.write(piece);
            _changedSoon();
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
    if (_closed) return null;
    var text = en.clean(writing.toString(), speaker);
    writing.clear();
    _changed();
    if (failed != null) say('The model stopped: ${short(failed!)}');
    if (speaker == null) {
      final split = StoryEngine.splitPlace(text);
      if (split.place != null) await _setPlace(split.place!);
      text = split.text;
    }
    if (text.isEmpty) return null;
    await add(
      speaker == null ? TurnKind.narrator : TurnKind.character,
      text,
      speakerId: speaker,
      speaker: speaker == null ? '' : en.nameOf(speaker),
    );
    if (speaker == null) _newNarration.add(text);
    return whole && failed == null ? text : null;
  }

  /// Lore entries close in meaning to the last few turns, found with the
  /// Recall model when it's downloaded; none otherwise, or on any trouble
  /// (key words still work then).
  Future<List<LoreEntry>> _loreByMeaning() async {
    final en = engine!;
    final entries = en.loreEntries;
    final recall = _services.recall;
    final text = en.recentText(turns);
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

  static String short(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// Stops the reply being written; what's there so far is kept.
  void stop() {
    _jumpIn = true;
    _stream?.cancel();
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete(false);
  }

  /// Writes the last reply again.
  Future<void> retry() async {
    final last = turns.lastOrNull;
    if (last == null || busy || last.kind.byHuman || last.kind.aside) return;
    await _log!.dropFrom(last.id);
    turns = turns.where((t) => t.id < last.id).toList();
    _changed();
    await run(
      last.kind == TurnKind.character ? last.speakerId : null,
      chain: false,
    );
  }

  /// Whether the last turn can be written again.
  bool get canRetry {
    final last = turns.lastOrNull;
    return last != null && !busy && !last.kind.byHuman && !last.kind.aside;
  }

  Future<void> edit(int id, String text) async {
    text = text.trim();
    if (text.isEmpty || _log == null) return;
    await _log!.edit(id, text);
    turns = [for (final t in turns) t.id == id ? t.copyWith(text: text) : t];
    _changed();
  }

  /// Removes turn [id] and everything after it.
  Future<void> rewind(int id) async {
    if (busy || _log == null) return;
    await _log!.dropFrom(id);
    turns = turns.where((t) => t.id < id).toList();
    _changed();
  }

  Future<void> makeRecap() async {
    final en = engine;
    if (en == null || recapping || busy) return;
    recapping = true;
    recap = null;
    _changed();
    String? text;
    try {
      final ask = en.recap(turns);
      final reply = await _services.models.ask(
        ask.system,
        ask.user,
        maxTokens: 900,
        what: 'Previously on…',
      );
      text = reply
          .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .replaceFirst(
            RegExp(r'^\W*previously on[^\n]*\n', caseSensitive: false),
            '',
          )
          .trim();
    } on Object catch (e) {
      _services.log.add(LogKind.errors, 'Recap failed: $e');
    }
    if (_closed) return;
    recapping = false;
    recap = text == null || text.isEmpty ? null : text;
    _changed();
    if (recap == null) say('The recap couldn\'t be written this time.');
  }

  void closeRecap() {
    recap = null;
    recapping = false;
    _changed();
  }

  /// Picture tags for the moment at [upTo], written by the chat model with
  /// the looks of those in view; empty when it gave none.
  Future<String> sceneTags(StoryTurn upTo) async {
    final en = engine!;
    final adult = en.mature && en.world.world.adult;
    try {
      final reply = await _services.models.ask(
        SceneTags.instructions(adult: adult),
        SceneTags.brief(en, turns, upTo, place: state.place),
        maxTokens: 1200,
        what: 'Scene tags',
        exact: true,
      );
      return SceneTags.prompt(reply, en.world.cast.values);
    } on Object catch (e) {
      _services.log.add(LogKind.errors, 'Scene tags failed: $e');
      return '';
    }
  }

  /// Keeps [kept] (a picture drawn for the scene) in the story's folder
  /// and adds it as a turn.
  Future<void> addScenePicture(File kept) async {
    final en = engine!;
    final dir = Directory(p.join(en.world.folder, 'pictures'));
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
    if (!_closed) {
      await add(TurnKind.picture, p.relative(to.path, from: en.world.folder));
    }
  }

  /// Marks a scene picture being made, so no second one starts.
  void setDrawing(bool on) {
    drawing = on;
    _changed();
  }

  /// Draws the moment at [upTo] straight away, with the picture model
  /// Drawing uses, and adds it to the story: for a phone, which has no
  /// Draw panel to check the tags in first.
  Future<void> drawScene(StoryTurn upTo) async {
    final en = engine;
    if (en == null || busy || drawing) return;
    final services = _services;
    final s = services.settings.value;
    if (s.imageEngine == ImageEngineChoice.off) {
      say('Turn on drawing in Settings → Images on your PC first.');
      return;
    }
    final ready = services.imageEngine.available(s);
    if (ready.isEmpty) {
      say('Download a picture model in Settings → Images on your PC first.');
      return;
    }
    setDrawing(true);
    try {
      say('Writing picture tags for the scene…');
      final prompt = await sceneTags(upTo);
      if (_closed) return;
      if (prompt.isEmpty) {
        say('The model gave no tags for this scene.');
        return;
      }
      final model =
          ready.where((m) => m.id == s.draw.model).firstOrNull ??
          ImageCatalog.defaultFor(s, ready)!;
      final job = services.imageEngine.draw(
        DrawJob(
          DrawRequest(model: model, prompt: prompt, shape: 'landscape'),
          folder: library.drawingFolder,
          forChat: false,
        ),
      );
      final file = await job.done;
      if (_closed) return;
      await addScenePicture(file);
    } on Object catch (e) {
      say('The scene couldn\'t be drawn: ${short(e)}');
    } finally {
      // Drawing let the chat model go; have it ready for the next turn.
      services.runtime.ensureReady(services.settings.value).ignore();
      setDrawing(false);
    }
  }

  /// The story after its world was brought up to date ([saved]).
  Future<void> useWorldUpdate(StorySave saved) async {
    final world = await library.storyWorld(saved);
    if (_closed) return;
    story = saved;
    engine = StoryEngine(world, mature: _services.settings.value.vocesMature);
    _changed();
  }

  /// Deletes the whole story, for good.
  Future<void> deleteStory() async {
    stop();
    await _log?.close();
    _log = null;
    await _services.deleteStoryLog(story.id);
    await library.deleteStory(story.id);
  }

  /// The picture file a picture turn shows, or null when it's gone.
  File? pictureOf(StoryTurn t) {
    final en = engine;
    if (en == null || t.kind != TurnKind.picture) return null;
    final f = File(p.join(en.world.folder, t.text));
    return f.existsSync() ? f : null;
  }
}
