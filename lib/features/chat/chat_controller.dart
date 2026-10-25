import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart' show ChangeNotifier, DateUtils;
import 'package:http/http.dart' as http;

import '../../app_scope.dart';
import '../../data/core_rules.dart';
import '../../data/desk/desk_files.dart';
import '../../data/desk/desk_tools.dart';
import '../../data/desk/pictures.dart';
import '../../data/memory/memory_tools.dart';
import '../../data/message_repository.dart';
import '../../data/settings.dart';
import '../../services/llm_client.dart';
import '../../services/system/system_tools.dart';
import 'prompt_history.dart';

enum ChatPhase {
  idle,

  /// Loading the model before the first word.
  waking,
  thinking,
  typing,

  /// Running memory tools between rounds.
  remembering,
}

/// Runs the conversation: builds the prompt (core file + recalled memories +
/// recent history), streams the reply and runs memory tool calls. Also backs
/// the day list, so one instance is shared by the chat screen and the card.
class ChatController extends ChangeNotifier {
  /// The tools offered; the system ones only while system access is on.
  static List<Map<String, Object?>> toolsFor(AppSettings s) => [
    ...MemoryTools.definitions,
    ...DeskTools.definitions,
    if (s.systemAccess) ...SystemTools.definitions,
  ];

  ChatController(this._services);

  final AppServices _services;
  final List<ChatMessage> messages = [];

  /// Local days that have messages, newest first.
  List<DateTime> days = const [];

  /// The past day being viewed, or null for the live conversation.
  DateTime? viewingDay;

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
  static const _historyTurns = 40;

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
    notifyListeners();
  }

  /// Sends a message. [images] are picture files the human shares: each is
  /// copied into the companion's folder and named in the message.
  Future<void> send(String text, {List<String> images = const []}) async {
    if (busy || (text.trim().isEmpty && images.isEmpty)) return;
    if (viewingDay != null) await load();
    final folder = _services.settings.value.companionFolder;
    final shared = [
      if (folder != null)
        for (final image in images)
          Pictures.marker(await Pictures.share(folder, image, DateTime.now())),
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

  static const _aboutPictures =
      '## Pictures\n'
      'When your human shares a picture, it is saved in your folder and '
      'their message shows [image: path]. You cannot see pictures yet, so '
      'never guess what one shows; ask them. Your portrait is yours to '
      'choose: to use a picture as your portrait, call set_avatar with its '
      'path. If they ask about your portrait, tell them they can share a '
      'picture in the chat.';

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
    ChatMessage userMsg,
    Set<String> seen,
  ) async {
    var askedHuman = false;
    for (final c in calls) {
      final skip = skipCall(c, seen: seen, askedHuman: askedHuman);
      askedHuman = askedHuman || SystemTools.names.contains(c.name);
      final result = skip != null
          ? jsonEncode({'ok': false, 'error': skip})
          : SystemTools.names.contains(c.name)
          ? await _services.systemTools.call(c.name, c.parsedArguments)
          : DeskTools.names.contains(c.name)
          ? await _services.deskTools.call(c.name, c.parsedArguments)
          : await _services.memoryTools.call(
              c.name,
              c.parsedArguments,
              sourceIds: [userMsg.id],
            );
      prompt.add({'role': 'tool', 'tool_call_id': c.id, 'content': result});
      if ((jsonDecode(result) as Map)['ok'] == true) {
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
          _ => null,
        };
        // Several changes in one reply are listed together.
        if (note != null && !(toolNote?.contains(note) ?? false)) {
          toolNote = toolNote == null ? note : '$toolNote · $note';
        }
        if (MemoryTools.names.contains(c.name)) _services.memoryChanged();
      }
    }
  }

  Future<void> _respond(ChatMessage userMsg) async {
    final settings = _services.settings.value;
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
    String shown() => cutEndMark(buffer.toString()).text;
    var endMarked = false;
    final thoughts = StringBuffer();
    var looped = false;
    var lastFinish = '';

    try {
      final target = await _services.runtime.ensureReady(settings);
      if (_stopRequested) throw const _Stopped();
      phase = ChatPhase.thinking;
      notifyListeners();
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
      final recalled = await _services.memory.recall(userMsg.content);
      final prompt = <Map<String, Object?>>[
        {
          'role': 'system',
          'content':
              '${howYouTalk(settings)}\n\n'
              '$core\n\n'
              '## Your human\n'
              '${aboutHuman(settings)}\n\n'
              '$_aboutPictures\n\n'
              '# Your personality file (personality.md)\n\n'
              '${desk.personality}\n\n'
              '${desk.lessons}\n\n'
              '## What you remember\n'
              '${MemoryTools.formatForPrompt(recalled)}\n\n'
              // Last before the clock: small models follow what they read
              // most recently.
              '${aboutComputer(settings)}\n\n'
              '## Right now\n${timeNote(DateTime.now())}',
        },
        ...alternatingHistory(
          messages.skip(max(0, messages.length - _historyTurns)),
        ),
      ];

      var reply = await _services.messages.add('assistant', '');
      replyId = reply.id;
      messages.add(reply);

      final tools = toolsFor(settings);
      final toolNames = {
        for (final t in tools) (t['function'] as Map)['name'] as String,
      };
      // Repeats are skipped across the whole reply.
      final seen = <String>{};
      var actedFirst = false;
      // Roleplay models often answer "open my Pictures folder" in character
      // without calling anything, so a plain request like that is put to
      // the human by the app itself, and the model replies knowing how it
      // went.
      if (settings.systemAccess) {
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
          await _runCalls([call], prompt, userMsg, seen);
          actedFirst = true;
          phase = ChatPhase.thinking;
          notifyListeners();
        }
      }
      for (var round = 0; round <= _maxToolRounds; round++) {
        List<ToolCall>? calls;
        var checkedText = buffer.length, checkedThoughts = thoughts.length;
        endMarked = false;
        await for (final event in client.chat(prompt, tools: tools)) {
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
              if (known.isNotEmpty) calls = known;
          }
          // Leaving the loop closes the stream, which stops the server.
          if (looped) break;
        }
        lastFinish = client.finishReason ?? '';
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
        prompt.add({
          'role': 'assistant',
          'content': shown(),
          'tool_calls': [for (final c in calls) c.toJson()],
        });
        await _runCalls(calls, prompt, userMsg, seen);
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
      days = await _services.messages.days();
      notifyListeners();
    }
  }
}

/// Thrown when Stop is pressed before the request was sent.
class _Stopped implements Exception {
  const _Stopped();
}
