import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' show ChangeNotifier, DateUtils;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/core_rules.dart';
import '../../data/desk/desk_files.dart';
import '../../data/desk/desk_tools.dart';
import '../../data/desk/pictures.dart';
import '../../data/desk/shared_files.dart';
import '../../data/memory/memory_tools.dart';
import '../../data/message_repository.dart';
import '../../data/schedule/schedule_repository.dart';
import '../../data/schedule/schedule_tools.dart';
import '../../data/settings.dart';
import '../../data/skills/skill_tools.dart';
import '../../data/skills/skills.dart';
import '../../services/images/draw_tools.dart';
import '../../services/images/image_engine.dart';
import '../../services/llm_client.dart';
import '../../services/logs/app_log.dart';
import '../../services/runtime/model_catalog.dart';
import '../../services/schedule/poke.dart';
import '../../services/schedule/scheduler.dart';
import '../../services/sight.dart';
import '../../services/story/story_keeper.dart';
import '../../services/system/system_tools.dart';
import '../../services/web/web_tools.dart';
import 'attachments_prompt.dart';
import 'chat_text.dart';
import 'prompt_history.dart';

enum ChatPhase {
  idle,

  /// Loading the model before the first word.
  waking,
  thinking,
  typing,

  /// Running memory tools between rounds.
  remembering,

  /// Eyes is looking at a shared picture.
  looking,
}

/// Runs the conversation: builds the prompt (core file + recalled memories +
/// recent history), streams the reply and runs memory tool calls. Also backs
/// the day list, so one instance is shared by the chat screen and the card.
class ChatController extends ChangeNotifier {
  /// The tools offered: the web ones while Settings → Internet allows
  /// them, the system ones only while system access is on and someone is
  /// there to approve them ([unattended] is a scheduled task).
  static List<Map<String, Object?>> toolsFor(
    AppSettings s, {
    bool unattended = false,
  }) => [
    ...MemoryTools.definitions,
    ...DeskTools.definitions,
    ...ScheduleTools.definitions,
    ...SkillTools.definitions,
    ...DrawTools.definitionsFor(s),
    ...WebTools.definitionsFor(s),
    if (s.systemAccess && !unattended) ...SystemTools.definitions,
  ];

  ChatController(this._services);

  final AppServices _services;
  final List<ChatMessage> messages = [];

  /// Local days that have messages, newest first.
  List<DateTime> days = const [];

  /// The past day being viewed, or null for the live conversation.
  DateTime? viewingDay;

  /// Goes up each time the messages are loaded afresh, the present or a
  /// past day, so the chat knows to start over at the right end.
  int loads = 0;

  /// What the human was writing and the files picked to go with it, kept
  /// here so they survive a visit to another tab.
  String draft = '';
  final draftPictures = <String>[];
  final draftFiles = <String>[];

  bool busy = false;
  String? error;

  /// What the companion is doing right now, for the status line.
  ChatPhase phase = ChatPhase.idle;

  /// Short status line shown under the reply, e.g. "Saved a memory".
  String? toolNote;

  /// How far the built-in runtime is through reading the chat before it
  /// answers, from 0 to 1, or null when it isn't reporting.
  double? reading;

  static const _maxToolRounds = 3;

  /// Most tokens one round may write, thoughts included.
  static const maxReplyTokens = 4096;

  /// How long the model may stay silent before the reply is given up:
  /// first while it reads the prompt (long on a CPU), then between words.
  static const firstWait = Duration(minutes: 5);
  static const stallWait = Duration(seconds: 90);

  /// Streamed words are drawn at most this often, not once per token.
  static const _frame = Duration(milliseconds: 50);
  Timer? _frameTimer;

  void _notifySoon() {
    _frameTimer ??= Timer(_frame, () {
      _frameTimer = null;
      notifyListeners();
    });
  }

  Future<void> load() async {
    viewingDay = null;
    messages
      ..clear()
      ..addAll(
        (await _services.messages.recent()).map(_clean).where(_hasSomething),
      );
    days = await _services.messages.days();
    loads++;
    notifyListeners();
  }

  /// Replies saved by an older version may end in a written-out end mark.
  static ChatMessage _clean(ChatMessage m) =>
      m.role == 'assistant' ? m.withContent(cutEndMark(m.content).text) : m;

  /// Replies left empty by an older version would show as typing forever.
  static bool _hasSomething(ChatMessage m) =>
      m.role != 'assistant' ||
      m.content.isNotEmpty ||
      (m.reasoning?.isNotEmpty ?? false);

  /// Shows one past day read-only; sending a message returns to the present.
  Future<void> showDay(DateTime day) async {
    final today = DateTime.now();
    if (DateUtils.isSameDay(day, today)) return load();
    viewingDay = day;
    messages
      ..clear()
      ..addAll(
        (await _services.messages.forDay(day)).map(_clean).where(_hasSomething),
      );
    loads++;
    notifyListeners();
  }

  /// Sends a message. [images] are picture files and [files] text files
  /// the human shares: each is copied into the companion's folder and
  /// named in the message.
  Future<void> send(
    String text, {
    List<String> images = const [],
    List<String> files = const [],
  }) async {
    if (busy || (text.trim().isEmpty && images.isEmpty && files.isEmpty)) {
      return;
    }
    if (viewingDay != null) await load();
    final folder = _services.settings.value.companionFolder;
    final now = DateTime.now();
    final shared = [
      if (folder != null) ...[
        for (final image in images)
          Pictures.marker(await Pictures.share(folder, image, now)),
        for (final file in files)
          SharedFiles.marker(await SharedFiles.share(folder, file, now)),
      ],
    ];
    final content = [
      text.trim(),
      shared.join('\n'),
    ].where((part) => part.isNotEmpty).join('\n\n');
    if (content.isEmpty) return;
    final userMsg = await _services.messages.add('user', content);
    messages.add(userMsg);
    await _respond(userMsg);
  }

  /// Whether the last reply failed or was stopped, and can be tried again.
  bool get canRetry =>
      (error != null || stopped) &&
      !busy &&
      viewingDay == null &&
      messages.isNotEmpty;

  /// The human stopped the last reply; what came so far is kept.
  bool stopped = false;

  /// Stop was pressed and the reply is winding down.
  bool get stopping => _stopRequested && busy;
  bool _stopRequested = false;
  http.Client? _http;

  /// Stops the reply being written. Closing the connection also makes
  /// llama-server stop generating.
  void stop() {
    if (!busy || _stopRequested) return;
    _stopRequested = true;
    _http?.close();
    notifyListeners();
  }

  /// Tries the failed reply again, for the same message.
  Future<void> retry() async {
    if (!canRetry) return;
    if (messages.last.role == 'assistant') return regenerate();
    await _respond(messages.last);
  }

  /// Replaces the last reply with a fresh one.
  Future<void> regenerate() async {
    if (busy || viewingDay != null || messages.isEmpty) return;
    // A reminder or task reply answered no message of the human's.
    if (const {
      'reminder',
      'automation',
      'picture',
      Poke.via,
    }.contains(messages.last.via)) {
      return;
    }
    if (messages.last.role == 'assistant') {
      await _services.messages.delete(messages.removeLast().id);
    }
    final lastUser = messages.lastWhere(
      (m) => m.role == 'user',
      orElse: () => throw StateError('Nothing to regenerate'),
    );
    await _respond(lastUser);
  }

  Future<void> delete(ChatMessage m) async {
    if (busy) return;
    await _services.messages.delete(m.id);
    messages.removeWhere((x) => x.id == m.id);
    days = await _services.messages.days();
    notifyListeners();
  }

  /// The human's message that [reply] answered, when [reply] is the last
  /// message: deleting that reply takes it too, so the chat doesn't end on
  /// a message with no answer.
  ChatMessage? questionFor(ChatMessage reply) {
    if (reply.role != 'assistant' || messages.isEmpty) return null;
    if (messages.last.id != reply.id) return null;
    for (var i = messages.length - 2; i >= 0; i--) {
      if (messages[i].role == 'user') return messages[i];
    }
    return null;
  }

  /// How many messages came after [m], so the screen can offer to delete
  /// them too.
  Future<int> countAfter(ChatMessage m) => _services.messages.countAfter(m);

  /// Rewinds the chat: deletes [m] and everything after it, on any day.
  Future<void> deleteFrom(ChatMessage m) async {
    if (busy) return;
    await _services.messages.deleteFrom(m);
    messages.removeWhere((x) => x.sortOrder >= m.sortOrder);
    error = null;
    stopped = false;
    toolNote = null;
    days = await _services.messages.days();
    notifyListeners();
  }

  /// What the companion is told about shared pictures and files, for how
  /// it sees them.
  static String aboutPictures(SightMode mode) =>
      '## Pictures and files\n'
      '${switch (mode) {
        SightMode.native => 'When your human shares a picture, you see it with their message, and it is saved in your folder as [image: path]. Look closely and react to what is really there; never make up details you can\'t see.',
        SightMode.eyes => 'When your human shares a picture, it is saved in your folder and their message shows [image: path. You see: …] with what is in it. That is what you see: react to it as if you looked at it yourself, and never mention a description.',
        SightMode.none => 'When your human shares a picture, it is saved in your folder and their message shows [image: path]. You can\'t see pictures, so never guess what one shows; ask them, and tell them they can let you see pictures in Settings → Brain.',
      }} '
      'Your portrait is yours to choose: to use a picture as your portrait, '
      'call set_avatar with its path. If they ask about your portrait, tell '
      'them they can share a picture in the chat.\n'
      'When they share a file, its text follows [file: path] in their '
      'message. It is saved in your folder, and read_file reads it again '
      'later.';

  /// Server-hosted models that turned a picture down this session; they
  /// get Eyes, or are told they can't see.
  final _blind = <String>{};

  /// Server-hosted models that have no endpoint taking tools; they get
  /// plain chat, without memory or other tools.
  final _noTools = <String>{};

  /// Context sizes of server-hosted models, by [Sight.serverKey], learned
  /// when one turned a prompt down as too long.
  final _serverCtx = <String, int>{};

  /// How far [estimateTokens] was off for each model, from the server's own
  /// count when it turned a prompt down.
  final _tokenScale = <String, double>{};

  static String _modelKey(AppSettings s) => s.llmMode == LlmMode.builtIn
      ? 'builtin:${s.modelPath}'
      : Sight.serverKey(s);

  /// Estimated tokens the prompt may take in a context of [ctx] tokens,
  /// leaving room for the reply.
  int _budget(AppSettings s, int ctx) =>
      ((ctx - replyRoom(ctx, maxReplyTokens)) /
              (_tokenScale[_modelKey(s)] ?? 1))
          .floor();

  /// The context the prompt has to fit: the memory span the built-in
  /// runtime was started with, or what a server-hosted model said its
  /// limit is. Null while a server-hosted model's limit is unknown.
  int? _contextFor(AppSettings s) =>
      s.llmMode == LlmMode.builtIn ? s.contextSize : _serverCtx[_modelKey(s)];

  /// Whether [e] is a server saying the model can't be given tools.
  static bool refusedTools(LlmException e) =>
      RegExp(r'^HTTP (400|404)\b').hasMatch(e.message) &&
      RegExp(
        r'support tool|tool use|tool calling|function calling',
        caseSensitive: false,
      ).hasMatch(e.message);

  /// Whether [e] is a server turning down a request because of its
  /// pictures: a model that can't take them.
  static bool refusedPictures(LlmException e) =>
      RegExp(r'^HTTP (400|404|413|415|422)\b').hasMatch(e.message) &&
      RegExp(
        r'image|vision|multimodal|modalit',
        caseSensitive: false,
      ).hasMatch(e.message);

  /// The pictures for one reply, each turned into a `data:` URL once.
  PromptAttachments _attachments(
    AppSettings settings,
    SightMode mode,
    String folder,
  ) {
    final urls = <String, Future<String?>>{};
    return PromptAttachments(
      folder: folder,
      mode: mode,
      notes: _services.pictureNotes,
      // About a third of the memory span, at roughly 4 characters a token.
      fileChars: settings.contextSize * 4 ~/ 3,
      pictureUrl: (rel) => urls[rel] ??= () async {
        final file = Pictures.fileIn(folder, rel);
        if (file == null || !await file.exists()) return null;
        try {
          return await Sight.dataUrl(file);
        } on Object {
          return null;
        }
      }(),
      look: (rel, said) async {
        final file = Pictures.fileIn(folder, rel);
        if (file == null || !await file.exists()) return null;
        phase = ChatPhase.looking;
        notifyListeners();
        try {
          final description = await _services.runtime.describePicture(
            settings,
            await Sight.dataUrl(file),
            said: said,
          );
          await _services.pictureNotes.put(
            rel,
            description,
            seenBy: ModelCatalog.eyes.name,
          );
          return description;
        } on Object {
          return null;
        } finally {
          phase = ChatPhase.thinking;
          notifyListeners();
        }
      },
    );
  }

  /// Adds [note] to the line under the reply.
  void _addNote(String note) {
    toolNote = toolNote == null ? note : '$toolNote · $note';
    _log(LogKind.chat, note);
  }

  /// Settings → Logs.
  void _log(
    LogKind kind,
    String message, {
    String details = '',
    bool error = false,
  }) => _services.log.add(kind, message, details: details, error: error);

  String _systemPrompt(
    AppSettings settings,
    SightMode mode, {
    required String core,
    required ({String personality, String lessons}) desk,
    required String recalled,
    required String story,
    required String moments,
    required String skills,
    required String drawing,
  }) =>
      '${howYouTalk(settings)}\n\n'
      '$core\n\n'
      '## Your human\n'
      '${aboutHuman(settings)}\n\n'
      '${aboutPictures(mode)}\n\n'
      '$drawing\n\n'
      '# Your personality file (personality.md)\n\n'
      '${desk.personality}\n\n'
      '${desk.lessons}\n\n'
      '## What you remember\n'
      '$recalled\n\n'
      '${story.isEmpty ? '' : '$story\n\n'}'
      '${moments.isEmpty ? '' : '$moments\n\n'}'
      '${_noTools.contains(Sight.serverKey(settings)) ? '$aboutTextTools\n\n' : ''}'
      '${aboutInternet(settings)}\n\n'
      '${aboutSchedule()}\n\n'
      '$skills\n\n'
      // Last before the clock: small models follow what they read most
      // recently.
      '${aboutComputer(settings)}\n\n'
      '## Right now\n${timeNote(DateTime.now())}';

  /// What the human plainly asked to have opened: a usual folder, an
  /// address, or one of their installed apps by name ("open Vivaldi
  /// please"). Null when it's left to the model.
  Future<String?> _requestedTarget(String text) async {
    if (requestedOpen(text) case final target?) return target;
    for (final words in requestedApp(text)) {
      final app = await _services.systemTools.apps.find(words, strict: true);
      if (app != null) return app.name;
    }
    return null;
  }

  /// Runs the tool calls of one round and adds their results to [prompt].
  Future<void> _runCalls(
    List<ToolCall> calls,
    List<Map<String, Object?>> prompt,
    List<String> sourceIds,
    Set<String> seen,
  ) async {
    var askedHuman = false;
    for (final c in calls) {
      final skip =
          skipCall(c, seen: seen, askedHuman: askedHuman) ??
          // Text from the web may have asked for this.
          (_readWeb && SystemTools.names.contains(c.name)
              ? 'Not run: after reading the web, computer requests wait for '
                    'your human\'s next message. Ask them if they want it.'
              : null);
      askedHuman = askedHuman || SystemTools.names.contains(c.name);
      if (WebTools.names.contains(c.name)) _readWeb = true;
      final result = skip != null
          ? jsonEncode({'ok': false, 'error': skip})
          : SystemTools.names.contains(c.name)
          ? await _services.systemTools.call(c.name, c.parsedArguments)
          : WebTools.names.contains(c.name)
          ? await _services.webTools.call(
              c.name,
              c.parsedArguments,
              unattended: _unattended,
            )
          : ScheduleTools.names.contains(c.name)
          ? await _services.scheduleTools.call(c.name, c.parsedArguments)
          : SkillTools.names.contains(c.name)
          ? await _services.skillTools.call(c.name, c.parsedArguments)
          : DrawTools.names.contains(c.name)
          ? await _services.drawTools.call(c.name, c.parsedArguments)
          : DeskTools.names.contains(c.name)
          ? await _services.deskTools.call(c.name, c.parsedArguments)
          : await _services.memoryTools.call(
              c.name,
              c.parsedArguments,
              sourceIds: sourceIds,
            );
      prompt.add({'role': 'tool', 'tool_call_id': c.id, 'content': result});
      final ok = (jsonDecode(result) as Map)['ok'] == true;
      _log(
        LogKind.decisions,
        skip != null
            ? 'Skipped ${c.name}: $skip'
            : '${c.name}${ok ? '' : ' (failed)'}',
        details: 'Arguments: ${c.arguments}\nResult: $result',
        error: !ok && skip == null,
      );
      if (ok) {
        final text = c.parsedArguments['text'];
        final what = text is String ? ': "${shortNote(text)}"' : '';
        final note = switch (c.name) {
          'remember' => 'Remembered$what',
          'update_memory' => 'Updated a memory$what',
          'forget' => 'Forgot a memory',
          'learn_lesson' => 'Learned a lesson',
          'set_avatar' => 'Changed portrait',
          'set_background' => 'Changed the look of the app',
          'set_theme' => switch (c.parsedArguments['theme']) {
            'light' => 'Switched to light mode',
            'dark' => 'Switched to dark mode',
            _ => 'Let the app follow your computer\'s theme',
          },
          'run_command' => 'Ran a command',
          'open' => 'Opened ${c.parsedArguments['target']}',
          'edit_file' || 'write_file' => 'Saved ${c.parsedArguments['path']}',
          'set_reminder' => 'Set a reminder$what',
          'schedule_task' => 'Planned a task',
          'cancel_schedule' => 'Cancelled a reminder',
          SkillTools.useTool => 'Used the ${c.parsedArguments['name']} skill',
          DrawTools.drawTool => 'Drawing a picture',
          _ => WebTools.noteFor(c.name, c.parsedArguments),
        };
        // Several changes in one reply are listed together.
        if (note != null && !(toolNote?.contains(note) ?? false)) {
          toolNote = toolNote == null ? note : '$toolNote · $note';
        }
        if (MemoryTools.names.contains(c.name)) _services.memoryChanged();
      }
    }
  }

  /// Puts a picture the companion drew into the chat, once no reply is
  /// being written.
  Future<void> addPicture(DrawJob job, File picture) async {
    while (busy) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final rel = p.posix.joinAll(
      p.split(p.relative(picture.path, from: job.folder)),
    );
    final r = job.request;
    await _services.pictureNotes.put(
      rel,
      'You drew this with ${DrawTools.nameFor(r.model)}'
      '${r.loras.isEmpty ? '' : ' and ${r.loras.map((l) => l.name).join(', ')}'}. '
      'What you asked for: ${r.prompt}',
      seenBy: 'drawn',
    );
    // Drawn for another companion, which is no longer the one talked to.
    if (job.folder != _services.settings.value.companionFolder) return;
    if (viewingDay != null) await load();
    final m = await _services.messages.add(
      'assistant',
      Pictures.marker(rel),
      via: 'picture',
    );
    messages.add(m);
    if (toolNote == 'Drawing a picture') toolNote = null;
    days = await _services.messages.days();
    notifyListeners();
  }

  /// A picture that couldn't be drawn, said under the chat.
  void pictureFailed(Object error) {
    toolNote = 'The picture couldn\'t be drawn: $error';
    notifyListeners();
  }

  /// Pictures the companion drew, as it remembers them: what it asked for,
  /// which the picture's message doesn't say.
  Future<List<ChatMessage>> _withDrawnNotes(Iterable<ChatMessage> list) async {
    final out = <ChatMessage>[];
    for (final m in list) {
      if (m.via != 'picture') {
        out.add(m);
        continue;
      }
      final rel = Pictures.inText(m.content).firstOrNull;
      final note = rel == null ? null : await _services.pictureNotes.get(rel);
      out.add(
        m.withContent('[A picture you drew: ${rel ?? 'gone'}. ${note ?? ''}]'),
      );
    }
    return out;
  }

  /// Whether this reply read the web, which holds back computer requests
  /// until the human writes again.
  bool _readWeb = false;

  /// Whether this reply is a scheduled one, with nobody there to approve.
  bool _unattended = false;

  /// Writes a due reminder in the chat, or does a scheduled task and says
  /// how it went. Null when a reply is being written; the scheduler tries
  /// again shortly. [late] when it came due while VoxCordis was closed.
  Future<ScheduledOutcome?> runScheduled(
    Schedule item, {
    bool late = false,
  }) async {
    if (busy) return null;
    if (viewingDay != null) await load();
    await _respond(null, scheduled: item, late: late);
    final last = messages.lastOrNull;
    final wrote = last != null && last.role == 'assistant' && last.via != 'app'
        ? last.content
        : '';
    if (wrote.trim().isNotEmpty && error == null) {
      return ScheduledOutcome(ok: true, text: wrote);
    }
    if (item.kind == ScheduleKind.reminder) {
      // The reminder still reaches the human, in plain words.
      final m = await _services.messages.add(
        'assistant',
        '⏰ Reminder: ${item.text}',
        via: 'reminder',
      );
      messages.add(m);
      error = null;
      days = await _services.messages.days();
      notifyListeners();
      return ScheduledOutcome(ok: true, text: m.content);
    }
    return ScheduledOutcome(ok: false, text: error ?? 'Nothing was written.');
  }

  /// When the last poke was tried, so one that fails isn't retried every
  /// half minute.
  DateTime? _pokeTried;

  /// After a long quiet the companion does something on its own (see
  /// [Poke]). Null when it isn't time, or it didn't work out; a poke that
  /// failed leaves no error in the chat and waits for the next quiet spell.
  Future<ScheduledOutcome?> poke({DateTime? now, Random? random}) async {
    final s = _services.settings.value;
    final hours = s.pokeAfterHours;
    now ??= DateTime.now();
    if (busy || hours <= 0) return null;
    if (_pokeTried case final t? when now.difference(t).inHours < hours) {
      return null;
    }
    final recent = await _services.messages.recent(limit: 200);
    if (!Poke.due(
      recent,
      now,
      hours,
      quietFrom: s.pokeQuietFrom,
      quietUntil: s.pokeQuietUntil,
      repeat: s.pokeRepeat,
    )) {
      return null;
    }
    _pokeTried = now;
    if (viewingDay != null) await load();
    final tools = {
      for (final t in toolsFor(s, unattended: true))
        (t['function'] as Map)['name'] as String,
    };
    final idea = Poke.pick(tools, random);
    await _respond(
      null,
      poke: Poke.note(idea, humanName(s), now.difference(recent.last.ts)),
    );
    final last = messages.lastOrNull;
    if (error == null &&
        last != null &&
        last.via == Poke.via &&
        last.content.trim().isNotEmpty) {
      return ScheduledOutcome(ok: true, text: last.content);
    }
    error = null;
    notifyListeners();
    return null;
  }

  /// The note that starts a scheduled turn, in place of a human message.
  String _scheduledNote(Schedule item, AppSettings s, {required bool late}) {
    final human = humanName(s);
    final when = late
        ? ' It was due at ${Schedule.stamp(item.nextAt)}, but VoxCordis '
              'wasn\'t running then, so it is late.'
        : '';
    return item.kind == ScheduleKind.reminder
        ? '[Note from VoxCordis, not from $human: the reminder you set is due '
              'now: "${item.text}".$when Remind $human of it now in a short, '
              'natural message, in your own voice.]'
        : '[Note from VoxCordis, not from $human: time for the task you '
              'planned: "${item.text}".$when Do it now with your tools, then '
              'tell $human what you found or did, briefly, in your own '
              'voice. $human may be away from the computer, and nobody can '
              'approve anything right now.]';
  }

  Future<void> _respond(
    ChatMessage? userMsg, {
    Schedule? scheduled,
    bool late = false,
    String? poke,
  }) async {
    final settings = _services.settings.value;
    final query =
        scheduled?.text ??
        userMsg?.content ??
        // A poke recalls what the last talk was about.
        messages.lastOrNull?.content ??
        '';
    final sourceIds = [?userMsg?.id];
    _readWeb = false;
    _unattended = scheduled?.kind == ScheduleKind.task || poke != null;
    // A summary being written would keep this reply waiting.
    _services.storyKeeper.cancel();
    error = null;
    toolNote = null;
    stopped = false;
    _stopRequested = false;
    busy = true;
    phase = ChatPhase.waking;
    notifyListeners();
    String? replyId;
    final buffer = StringBuffer();
    // The reply without a chat-template end mark the model wrote out.
    String shown() => tidyBlankLines(cutEndMark(buffer.toString()).text);
    var endMarked = false;
    final thoughts = StringBuffer();
    var looped = false;
    var lastFinish = '';
    var started = DateTime.now();

    _services.runtime.hold();
    try {
      final target = await _services.runtime.ensureReady(settings);
      if (_stopRequested) throw const _Stopped();
      phase = ChatPhase.thinking;
      notifyListeners();
      started = DateTime.now();
      _log(
        LogKind.chat,
        'Writing a ${switch (scheduled?.kind) {
          null when poke != null => 'poke',
          null => 'reply',
          ScheduleKind.reminder => 'reminder',
          ScheduleKind.task => 'task',
        }} with ${target.model}',
      );
      final client = LlmClient(
        baseUrl: target.baseUrl,
        model: target.model,
        apiKey: target.apiKey,
        sampling: samplingFor(settings),
        stop: stopFor(settings),
        maxTokens: maxReplyTokens,
        progress: settings.llmMode == LlmMode.builtIn,
        firstWait: firstWait,
        stallWait: stallWait,
        client: _http = http.Client(),
      );
      final core = await CoreRules.load(settings);
      final desk = await DeskFiles.load(settings);
      // The prompt carries the story so far and the recent messages, as
      // they are; what is older is reached by meaning.
      final sofar = await _services.story.get();
      final recent = StoryKeeper.recent(messages, sofar?.through);
      final found = await _services.recall.recall(
        _recallQuery(query, userMsg),
        // The recent turns are in the prompt anyway.
        beforeSortOrder: recent.firstOrNull?.sortOrder,
      );
      final recalled = MemoryTools.formatForPrompt(found.memories);
      final story = aboutStory(sofar?.text);
      final moments = aboutMoments(found.moments, settings);
      if (found.memories.isNotEmpty || found.moments.isNotEmpty) {
        _log(
          LogKind.thinking,
          found.byMeaning
              ? 'Recalled by meaning'
              : 'Recalled by matching words',
          details: moments.isEmpty ? recalled : '$recalled\n\n$moments',
        );
      }
      final skillList = settings.companionFolder == null
          ? const <Skill>[]
          : await Skills.load(settings.companionFolder!);
      // "/weather in Bern" calls up a skill for this reply.
      final called = Skills.called(query, skillList);
      if (called != null) _addNote('Used the ${called.displayTitle} skill');
      final skills = Skills.forPrompt(
        skillList,
        called: called,
        contextSize: settings.contextSize,
      );
      final images = _services.imageEngine;
      if (settings.imageEngine == ImageEngineChoice.invoke) {
        // Asked once per address up front, then again in the background
        // so models added in Invoke show up by the next message.
        final ask = images.refreshInvoke(settings);
        if (images.invokeUrl != settings.invokeUrl) await ask;
      }
      final drawing = aboutDrawing(
        settings,
        images.available(settings),
        images.lorasFor(settings),
      );
      final history = alternatingHistory(await _withDrawnNotes(recent));
      final note = scheduled != null
          ? _scheduledNote(scheduled, settings, late: late)
          : poke;
      if (note != null) {
        // Templates want turns to alternate: after the human's own last
        // message the note joins it.
        if (history.isNotEmpty && history.last['role'] == 'user') {
          final last = history.removeLast();
          history.add({...last, 'content': '${last['content']}\n\n$note'});
        } else {
          history.add({'role': 'user', 'content': note});
        }
      }
      var mode = Sight.modeFor(settings, blind: _blind);
      final folder = settings.companionFolder;
      var attachments = folder == null
          ? null
          : _attachments(settings, mode, folder);
      final prompt = <Map<String, Object?>>[
        {
          'role': 'system',
          'content': _systemPrompt(
            settings,
            mode,
            core: core,
            desk: desk,
            recalled: recalled,
            story: story,
            moments: moments,
            skills: skills,
            drawing: drawing,
          ),
        },
        ...(await attachments?.expand(history) ?? history),
      ];
      if (attachments?.unseen.isNotEmpty ?? false) {
        _addNote('Eyes couldn\'t look at the picture');
      }
      if (_stopRequested) throw const _Stopped();
      phase = ChatPhase.thinking;
      notifyListeners();

      var reply = await _services.messages.add(
        'assistant',
        '',
        via: switch (scheduled?.kind) {
          null when poke != null => Poke.via,
          null => 'app',
          ScheduleKind.reminder => 'reminder',
          ScheduleKind.task => 'automation',
        },
      );
      replyId = reply.id;
      messages.add(reply);

      var tools = _noTools.contains(Sight.serverKey(settings))
          ? <Map<String, Object?>>[]
          : toolsFor(settings, unattended: _unattended);
      final toolNames = {
        for (final t in tools) (t['function'] as Map)['name'] as String,
      };
      // Older turns are left out so the prompt fits the model's context;
      // a long chat or a switch to a smaller model would overflow it.
      if (_contextFor(settings) case final ctx?) {
        final dropped = fitPrompt(
          prompt,
          history,
          tools: tools,
          budget: _budget(settings, ctx),
        );
        if (dropped > 0) {
          _log(
            LogKind.thinking,
            'Left out the $dropped oldest turns to fit the ${ctx ~/ 1024}k '
            'memory span',
          );
        }
      }
      var refits = 0;
      // Repeats are skipped across the whole reply.
      final seen = <String>{};
      var actedFirst = false;
      // Roleplay models often answer "open my Pictures folder" in character
      // without calling anything, so a plain request like that is put to
      // the human by the app itself, and the model replies knowing how it
      // went.
      if (settings.systemAccess && userMsg != null) {
        if (await _requestedTarget(userMsg.content) case final target?) {
          final call = ToolCall(
            'askedOpen', // nine letters, as Mistral's template wants
            SystemRequest.openTool,
            jsonEncode({
              'target': target,
              'why': 'You asked: "${shortNote(userMsg.content)}"',
            }),
          );
          prompt.add({
            'role': 'assistant',
            'content': '',
            'tool_calls': [call.toJson()],
          });
          phase = ChatPhase.remembering;
          notifyListeners();
          await _runCalls([call], prompt, sourceIds, seen);
          actedFirst = true;
          phase = ChatPhase.thinking;
          notifyListeners();
        }
      }
      for (var round = 0; round <= _maxToolRounds; round++) {
        List<ToolCall>? calls;
        var checkedText = buffer.length, checkedThoughts = thoughts.length;
        final thoughtsFrom = thoughts.length;
        endMarked = false;
        try {
          await for (final event in client.chat(
            prompt,
            tools: tools,
            textTools: _noTools.contains(Sight.serverKey(settings))
                ? MemoryTools.names
                : const {},
          )) {
            switch (event) {
              case PromptProgress(:final fraction):
                reading = fraction;
                _notifySoon();
              case TextDelta(:final text):
                // Past an end mark is the model writing on past its turn.
                if (endMarked) continue;
                buffer.write(text);
                final cut = cutEndMark(buffer.toString());
                if (cut.ended) {
                  endMarked = true;
                  buffer
                    ..clear()
                    ..write(cut.text);
                }
                reading = null;
                phase = ChatPhase.typing;
                if (buffer.length - checkedText >= 32) {
                  checkedText = buffer.length;
                  final all = buffer.toString();
                  if (loopCut(all) case final cut?) {
                    buffer
                      ..clear()
                      ..write(all.substring(0, cut).trimRight());
                    looped = true;
                  }
                }
                reply = reply.withContent(shown());
                messages[messages.length - 1] = reply;
                _notifySoon();
              case ReasoningDelta(:final text):
                thoughts.write(text);
                reading = null;
                phase = ChatPhase.thinking;
                if (thoughts.length - checkedThoughts >= 32) {
                  checkedThoughts = thoughts.length;
                  final all = thoughts.toString();
                  if (loopCut(all) case final cut?) {
                    thoughts
                      ..clear()
                      ..write(all.substring(0, cut).trimRight());
                    looped = true;
                  }
                }
                reply = reply.withContent(
                  shown(),
                  reasoning: thoughts.toString(),
                );
                messages[messages.length - 1] = reply;
                _notifySoon();
              case ToolCallsRequested(calls: final c):
                // Models sometimes invent tools; only run ours.
                final known = [
                  for (final x in c)
                    if (toolNames.contains(x.name)) withShortId(x),
                ];
                for (final x in c) {
                  if (!toolNames.contains(x.name)) {
                    _log(
                      LogKind.decisions,
                      'Asked for a tool it doesn\'t have: ${x.name}',
                      details: x.arguments,
                    );
                  }
                }
                if (known.isNotEmpty) calls = known;
            }
            // Leaving the loop closes the stream, which stops the server.
            if (looped) break;
          }
        } on LlmException catch (e) {
          // Still too long for the model, by the server's own count: learn
          // how far off the guess was, leave out more and ask again.
          if (promptOverflow(e.message) case final over? when refits < 2) {
            refits++;
            final key = _modelKey(settings);
            final guess = estimatePrompt(prompt, tools);
            if (over.prompt case final real? when guess > 0) {
              _tokenScale[key] = max(
                _tokenScale[key] ?? 1,
                real / guess * 1.05,
              );
            }
            if (over.ctx case final ctx?
                when settings.llmMode == LlmMode.external) {
              _serverCtx[key] = ctx;
            }
            final ctx = over.ctx ?? _contextFor(settings);
            final dropped = fitPrompt(
              prompt,
              history,
              tools: tools,
              budget: ctx != null ? _budget(settings, ctx) : guess * 3 ~/ 4,
            );
            _log(
              LogKind.chat,
              dropped > 0
                  ? 'The prompt was too long for the model; left out the '
                        '$dropped oldest turns and asked again'
                  : 'The prompt was too long for the model, with nothing '
                        'older left to leave out',
              details: e.message,
            );
            if (dropped > 0) {
              round--;
              continue;
            }
            throw LlmException(
              settings.llmMode == LlmMode.builtIn
                  ? 'This is too long for the ${settings.contextSize ~/ 1024}k '
                        'memory span. Send something shorter, or pick a '
                        'longer memory span in Settings → Brain.'
                  : 'This is too long for ${settings.llmModel}. Send '
                        'something shorter, or pick a model with a bigger '
                        'context.',
            );
          }
          // A server-hosted model with no tool support: ask again as plain
          // chat, and remember that.
          if (tools.isNotEmpty &&
              round == 0 &&
              buffer.isEmpty &&
              thoughts.isEmpty &&
              settings.llmMode == LlmMode.external &&
              refusedTools(e)) {
            _noTools.add(Sight.serverKey(settings));
            tools = [];
            prompt[0] = {
              ...prompt[0],
              'content': '${prompt[0]['content']}\n\n$aboutTextTools',
            };
            _addNote(
              '${settings.llmModel} can\'t use tools, so it remembers in a simpler way '
              'and other tools are off',
            );
            round--;
            continue;
          }
          // A server-hosted model that can't take pictures: send them
          // again as Eyes sees them, or as names, and remember that.
          if (round > 0 ||
              attachments == null ||
              !attachments.sentPictures ||
              buffer.isNotEmpty ||
              thoughts.isNotEmpty ||
              !refusedPictures(e)) {
            rethrow;
          }
          _blind.add(Sight.serverKey(settings));
          mode = Sight.modeFor(settings, blind: _blind);
          attachments = _attachments(settings, mode, folder!);
          prompt.replaceRange(0, 1 + history.length, [
            {
              'role': 'system',
              'content': _systemPrompt(
                settings,
                mode,
                core: core,
                desk: desk,
                recalled: recalled,
                story: story,
                moments: moments,
                skills: skills,
                drawing: drawing,
              ),
            },
            ...await attachments.expand(history),
          ]);
          _addNote(
            mode == SightMode.eyes
                ? '${settings.llmModel} can\'t see pictures, so Eyes looked'
                : '${settings.llmModel} can\'t see pictures',
          );
          round--;
          continue;
        }
        lastFinish = client.finishReason ?? '';
        if (thoughts.length > thoughtsFrom) {
          final t = thoughts.toString().substring(thoughtsFrom).trim();
          if (t.isNotEmpty) {
            _log(
              LogKind.thinking,
              round == 0 ? 'Thoughts' : 'Thoughts (after tools, round $round)',
              details: t,
            );
          }
        }
        if (looped ||
            calls == null ||
            round == _maxToolRounds ||
            _stopRequested) {
          break;
        }

        phase = ChatPhase.remembering;
        _frameTimer?.cancel();
        _frameTimer = null;
        notifyListeners();
        // Later rounds' thoughts go below the earlier ones.
        if (thoughts.isNotEmpty) thoughts.write('\n\n');
        if (tools.isEmpty) {
          // No tool support on the server: the call stays in the reply's
          // own words and the result comes back as a message.
          prompt.add({
            'role': 'assistant',
            'content': [
              shown(),
              for (final c in calls)
                '<tool_call>{"name": "${c.name}", "arguments": '
                    '${c.arguments}}</tool_call>',
            ].join('\n'),
          });
          final from = prompt.length;
          await _runCalls(calls, prompt, sourceIds, seen);
          final results = prompt.sublist(from);
          prompt.removeRange(from, prompt.length);
          prompt.add({
            'role': 'user',
            'content': [
              for (final r in results) '[Tool result: ${r['content']}]',
            ].join('\n'),
          });
        } else {
          prompt.add({
            'role': 'assistant',
            'content': shown(),
            'tool_calls': [for (final c in calls) c.toJson()],
          });
          await _runCalls(calls, prompt, sourceIds, seen);
        }
        notifyListeners();
      }
      stopped = _stopRequested;
      if (looped) {
        toolNote = toolNote == null
            ? 'Cut short: it was repeating itself'
            : '$toolNote · Cut short: it was repeating itself';
      }
      if (shown().trim().isEmpty && actedFirst && !stopped) {
        // The request was answered and the note under the chat says how it
        // went; a model with nothing to add leaves no empty bubble.
        await _services.messages.delete(reply.id);
        messages.removeWhere((m) => m.id == reply.id);
      } else if (shown().trim().isEmpty && !stopped) {
        // An empty reply would sit there looking like it is still typing.
        final name = settings.companionName;
        throw LlmException(
          looped
              ? '$name got stuck going round in circles while thinking, so '
                    'it was stopped. Try again.'
              : lastFinish == 'length'
              ? '$name used up the room for this reply while thinking. '
                    'Try again.'
              : '$name didn\'t write anything. Try again.',
        );
      }
      _log(
        LogKind.chat,
        '${stopped ? 'Stopped' : 'Replied'} after '
        '${DateTime.now().difference(started).inSeconds} s: '
        '${shown().length} characters'
        '${lastFinish.isEmpty ? '' : ', finish: $lastFinish'}'
        '${looped ? ', cut short for repeating itself' : ''}',
        details: shown(),
      );
      if (messages.any((m) => m.id == reply.id)) {
        await _services.messages.setContent(
          reply.id,
          shown(),
          reasoning: thoughts.toString().trim(),
        );
      }
    } catch (e) {
      if (_stopRequested) {
        // Not an error: keep what was written before Stop.
        stopped = true;
      } else {
        error = '$e';
        _log(
          LogKind.chat,
          'The reply failed: $e',
          details: [
            if (lastFinish.isNotEmpty) 'Finish: $lastFinish',
            if (buffer.isNotEmpty) 'Written so far:\n${shown()}',
          ].join('\n'),
          error: true,
        );
      }
      // Keep what was written so far, also when the reply failed.
      if (replyId != null && buffer.isNotEmpty) {
        await _services.messages.setContent(
          replyId,
          shown(),
          reasoning: thoughts.toString().trim(),
        );
      }
      if (messages.isNotEmpty &&
          messages.last.role == 'assistant' &&
          messages.last.content.isEmpty) {
        await _services.messages.delete(messages.removeLast().id);
      }
    } finally {
      if (stopped) {
        toolNote = toolNote == null ? 'Stopped' : '$toolNote · Stopped';
      }
      _frameTimer?.cancel();
      _frameTimer = null;
      _http?.close();
      _http = null;
      reading = null;
      _stopRequested = false;
      busy = false;
      phase = ChatPhase.idle;
      _services.runtime.release(_services.settings.value);
      days = await _services.messages.days();
      notifyListeners();
      // This exchange, and anything remembered, become findable by meaning.
      _services.recall.update(limit: 32, refresh: userMsg?.id).ignore();
      // Messages that aged out of the recent window join the story so far,
      // now that the human is reading the reply.
      if (!stopped && error == null) {
        _services.storyKeeper.catchUp().ignore();
      }
    }
  }

  /// What Recall looks for: the message, and when that is short ("yes",
  /// "tell me more") the end of the reply it answers, for what it is about.
  String _recallQuery(String query, ChatMessage? userMsg) {
    if (userMsg == null || query.trim().length >= 60) return query;
    final before = messages
        .where((m) => m.role == 'assistant' && m.sortOrder < userMsg.sortOrder)
        .lastOrNull;
    if (before == null || before.content.trim().isEmpty) return query;
    final t = before.content.trim();
    return '${t.length <= 400 ? t : t.substring(t.length - 400)}\n\n$query';
  }
}

/// Thrown when Stop is pressed before the request was sent.
class _Stopped implements Exception {
  const _Stopped();
}
