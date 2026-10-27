import 'dart:async';

import 'package:http/http.dart' as http;

import '../../data/message_repository.dart';
import '../../data/settings.dart';
import '../../data/story_repository.dart';
import '../../features/chat/chat_text.dart';
import '../../features/chat/prompt_history.dart';
import '../llm_client.dart';
import '../logs/app_log.dart';
import '../runtime/runtime_controller.dart';

/// Keeps the story so far: as messages age out of the prompt's recent
/// window, the model folds them into a short summary, in the background
/// right after a reply. The prompt then carries the summary and the recent
/// messages instead of a long history.
class StoryKeeper {
  StoryKeeper({
    required this.settings,
    required this.runtime,
    required this.messages,
    required this.story,
    this.log,
  });

  final AppSettings Function() settings;
  final RuntimeController runtime;
  final MessageRepository Function() messages;
  final StoryRepository Function() story;
  final AppLog? log;

  /// Recent messages the prompt carries as they are, once the story is up
  /// to date (six exchanges), and the most before some are folded in.
  static const window = 12;
  static const maxWindow = 18;

  /// Most messages folded in at once. The first time (or after a long
  /// backlog, say after an update) the story starts from these, just
  /// before the window; older chat is reached by meaning instead.
  static const foldAtMost = 16;

  /// About how long the story may get.
  static const maxWords = 250;

  /// Most tokens one update may write, with room for a model to think.
  static const maxTokens = 1500;

  http.Client? _http;
  Future<void>? _running;

  /// Whether an update is running.
  bool get busy => _running != null;

  /// The messages that go into the prompt as they are: those after the
  /// story, at most [maxWindow] of them. Null [through] means no story.
  static List<ChatMessage> recent(List<ChatMessage> all, int? through) {
    final after = through == null
        ? all
        : [
            for (final m in all)
              if (m.sortOrder > through) m,
          ];
    return after.length <= maxWindow
        ? after
        : after.sublist(after.length - maxWindow);
  }

  /// The messages to fold in now, oldest first: everything after the
  /// story but the last [window], the newest [foldAtMost] of them. Empty
  /// while the window is not yet past [maxWindow].
  static List<ChatMessage> toFold(List<ChatMessage> all, int? through) {
    final after = through == null
        ? all
        : [
            for (final m in all)
              if (m.sortOrder > through) m,
          ];
    if (after.length <= maxWindow) return const [];
    final old = after.sublist(0, after.length - window);
    return old.length <= foldAtMost
        ? old
        : old.sublist(old.length - foldAtMost);
  }

  /// Folds aged-out messages into the story if there are enough. Runs once
  /// at a time; a call while one runs is a no-op.
  Future<void> catchUp() {
    if (_running case final r?) return r;
    return _running = _catchUp().whenComplete(() => _running = null);
  }

  /// Stops an update under way, so the human's new message isn't kept
  /// waiting behind it. The messages are folded in after the next reply.
  void cancel() {
    final c = _http;
    _http = null;
    c?.close();
  }

  Future<void> _catchUp() async {
    final s = settings();
    final repo = story();
    final current = await repo.get();
    final all = await messages().after(current?.through ?? -1);
    final fold = toFold(all, current?.through);
    if (fold.isEmpty) return;
    final turns = alternatingHistory(fold);
    if (turns.isEmpty) {
      // Only empty or app messages: nothing to tell, but mark them read.
      await repo.set(current?.text ?? '', through: fold.last.sortOrder);
      return;
    }
    final client = _http = http.Client();
    runtime.hold();
    try {
      final target = await runtime.ensureReady(s);
      final llm = LlmClient(
        baseUrl: target.baseUrl,
        model: target.model,
        apiKey: target.apiKey,
        sampling: {...samplingFor(s), 'temperature': 0.3},
        stop: stopFor(s),
        maxTokens: maxTokens,
        firstWait: const Duration(minutes: 5),
        stallWait: const Duration(seconds: 90),
        client: client,
      );
      final text = StringBuffer();
      await for (final e in llm.chat(prompt(s, current?.text, turns))) {
        if (e is TextDelta) text.write(e.text);
      }
      final summary = tidyBlankLines(cutEndMark(text.toString()).text).trim();
      if (summary.isEmpty) {
        log?.add(
          LogKind.thinking,
          'The story so far wasn\'t updated: the model wrote nothing',
          error: true,
        );
        return;
      }
      // The human may have rewound the chat meanwhile.
      if (await messages().byIds([fold.last.id]) case []) return;
      await repo.set(summary, through: fold.last.sortOrder);
      log?.add(
        LogKind.thinking,
        'Updated the story so far with ${fold.length} messages',
        details: summary,
      );
    } on Object catch (e) {
      if (!identical(_http, client)) return; // cancelled
      log?.add(
        LogKind.thinking,
        'The story so far couldn\'t be updated',
        details: '$e',
        error: true,
      );
    } finally {
      client.close();
      if (identical(_http, client)) _http = null;
      runtime.release(settings());
    }
  }

  /// The request: the story so far and the messages to fold in, with the
  /// rules for the summary.
  static List<Map<String, Object?>> prompt(
    AppSettings s,
    String? sofar,
    List<Map<String, Object?>> turns,
  ) {
    final human = humanName(s);
    final name = s.companionName;
    return [
      {
        'role': 'system',
        'content':
            'You keep the running summary of a private chat between $human '
            'and $name, who is $human\'s companion. You will get the summary '
            'so far and the messages that come next. Write the summary '
            'anew so it covers everything so far: what they talked about, '
            'what was decided or planned, how they felt, what is still '
            'open. Keep what still matters weeks from now and drop small '
            'talk. Keep names, places, dates and details exactly right, and '
            'write in the language the chat is in.\n'
            'Rules: at most $maxWords words, plain prose, in the past tense, '
            'from $name\'s point of view ("$human told me…", "I suggested…"). '
            'Write only the summary: no heading, no notes, no asking.',
      },
      {
        'role': 'user',
        'content':
            'Summary so far:\n${sofar?.trim().isNotEmpty ?? false ? sofar : '(The chat has just begun.)'}\n\n'
            'What came next:\n'
            '${[for (final t in turns) '${t['role'] == 'user' ? human : name}: ${t['content']}'].join('\n\n')}\n\n'
            'Write the updated summary.',
      },
    ];
  }
}
