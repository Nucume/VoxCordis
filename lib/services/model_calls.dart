import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../data/settings.dart';
import '../features/chat/prompt_history.dart' show samplingFor, stopFor;
import 'llm_client.dart';
import 'logs/app_log.dart';
import 'runtime/llama_server.dart' show serverExitHint;
import 'runtime/runtime_controller.dart';

/// A client for the chat model at [target], set up the way every request
/// to it is: the model's samplers and the template's end marks from [s].
/// [sampling] goes on top of the samplers, [stop] after the end marks.
LlmClient chatClient(
  LlmTarget target,
  AppSettings s, {
  Map<String, num> sampling = const {},
  List<String> stop = const [],
  int? maxTokens,
  bool progress = false,
  Duration? firstWait,
  Duration? stallWait,
  Map<String, Object?> extra = const {},
  http.Client? client,
}) => LlmClient(
  baseUrl: target.baseUrl,
  model: target.model,
  apiKey: target.apiKey,
  sampling: sampling.isEmpty
      ? samplingFor(s)
      : {...samplingFor(s), ...sampling},
  stop: stop.isEmpty ? stopFor(s) : [...stopFor(s), ...stop],
  maxTokens: maxTokens,
  progress: progress,
  firstWait: firstWait,
  stallWait: stallWait,
  extra: extra,
  client: client,
);

/// Runs [body] with the chat model loaded, and kept loaded until it ends
/// however long that takes.
Future<T> withChatModel<T>(
  RuntimeController runtime,
  AppSettings Function() settings,
  Future<T> Function(LlmTarget target) body,
) async {
  runtime.hold();
  try {
    return await body(await runtime.ensureReady(settings()));
  } finally {
    runtime.release(settings());
  }
}

/// Questions to the chat model outside the companion's own replies: no
/// companion prompt, no tools. A connection that drops (the model server
/// crashed or was stopped) is logged with how the server ended, the model
/// is started again and the question asked once more.
class ModelCalls {
  ModelCalls({required this.runtime, required this.settings, this.log});

  final RuntimeController runtime;
  final AppSettings Function() settings;
  final AppLog? log;

  /// One answer from the chat model to [system] and [user]. Throws when
  /// the model can't be reached. [what] names the request in Logs →
  /// Thinking, which shows what came back. [exact] is for answers in a
  /// fixed form (tags, lists): the model is asked with a low temperature,
  /// so a roleplay model keeps to the form.
  Future<String> ask(
    String system,
    String user, {
    int maxTokens = 1500,
    String what = 'A helper request',
    bool exact = false,
  }) async {
    final s = settings();
    final connection = http.Client();
    runtime.hold();
    try {
      for (var drops = 0; ; drops++) {
        final target = await runtime.ensureReady(s);
        final client = chatClient(
          target,
          s,
          sampling: exact
              ? {
                  'temperature': min(
                    (samplingFor(s)['temperature'] ?? 0.3).toDouble(),
                    0.3,
                  ),
                }
              : const {},
          // Room for a model that thinks anyway: Gemma 4 finetunes like
          // Artemis thought past the whole budget and answered nothing.
          maxTokens: maxTokens + 4000,
          // A helper answer needs no thinking; llama-server turns it on
          // for templates that can think unless told not to.
          extra: s.llmMode == LlmMode.builtIn
              ? const {
                  'chat_template_kwargs': {'enable_thinking': false},
                }
              : const {},
          stallWait: const Duration(minutes: 2),
          client: connection,
        );
        final reply = StringBuffer();
        var thought = 0;
        try {
          await for (final e in client.chat(_asked(system, user))) {
            if (e is TextDelta) reply.write(e.text);
            if (e is ReasoningDelta) thought += e.text.length;
          }
        } on http.ClientException catch (e) {
          await _dropped(what, s, target, e, again: drops == 0);
          if (drops > 0) rethrow;
          continue;
        }
        final text = reply.toString();
        final shown = text.trim().replaceAll(RegExp(r'\s+'), ' ');
        log?.add(
          LogKind.thinking,
          '$what: the model answered '
          '${shown.isEmpty ? 'nothing' : '"${shown.length > 400 ? '${shown.substring(0, 400)}…' : shown}"'}'
          '${thought > 0 ? ' (after $thought characters of thinking)' : ''}.',
        );
        return text;
      }
    } on Object catch (e) {
      log?.add(LogKind.errors, '$what failed: $e');
      rethrow;
    } finally {
      connection.close();
      runtime.release(settings());
    }
  }

  /// The chat model's reply to [system] and [user], piece by piece, for a
  /// Voces Mundi story. [stop] adds lines that end the reply. Cancelling
  /// the subscription stops the model.
  ///
  /// With [again], a reply cut short by a dropped connection is written
  /// once more from its start: [again] is called first, for the listener
  /// to throw away the pieces it has. Without it the drop is an error.
  Stream<String> stream(
    String system,
    String user, {
    List<String> stop = const [],
    int maxTokens = 1200,
    String what = 'A story turn',
    void Function()? again,
  }) {
    final connection = http.Client();
    // Set when the listener left: nothing more is asked of the model, and
    // [again] is not called for a reply nobody waits for.
    var cancelled = false;
    late final StreamController<String> out;
    Future<void> run() async {
      final s = settings();
      runtime.hold();
      try {
        for (var drops = 0; ; drops++) {
          final target = await runtime.ensureReady(s);
          if (cancelled) return;
          final client = chatClient(
            target,
            s,
            stop: stop,
            maxTokens: maxTokens,
            stallWait: const Duration(minutes: 2),
            client: connection,
          );
          try {
            await for (final e in client.chat(_asked(system, user))) {
              if (cancelled) return;
              if (e is TextDelta) out.add(e.text);
            }
            return;
          } on http.ClientException catch (e) {
            if (cancelled) return;
            final retry = again != null && drops == 0;
            await _dropped(what, s, target, e, again: retry);
            if (cancelled) return;
            if (!retry) rethrow;
            again();
          }
        }
      } on Object catch (e, st) {
        if (!cancelled) out.addError(e, st);
      } finally {
        connection.close();
        runtime.release(settings());
        if (!cancelled) unawaited(out.close());
      }
    }

    out = StreamController<String>(
      onListen: run,
      onCancel: () {
        cancelled = true;
        connection.close();
      },
    );
    return out.stream;
  }

  static List<Map<String, Object?>> _asked(String system, String user) => [
    {'role': 'system', 'content': system},
    {'role': 'user', 'content': user},
  ];

  /// Notes in Logs → Errors that the connection for [what] dropped, with
  /// how the built-in server ended when it was ours.
  Future<void> _dropped(
    String what,
    AppSettings s,
    LlmTarget target,
    http.ClientException e, {
    required bool again,
  }) async {
    final exit = s.llmMode == LlmMode.builtIn
        ? await runtime.exitOf(target.baseUrl)
        : null;
    log?.add(
      LogKind.errors,
      '$what: the connection to the model dropped'
      '${exit == null
          ? ''
          : exit.onPurpose
          ? ' (the app restarted it)'
          : ' (it stopped: ${serverExitHint(exit.code, exit.log)})'}'
      '${again ? '; trying again' : ''}. ${e.message}'
      '${exit == null ? '' : '\nExit code: ${exit.code}'}'
      '${exit == null || exit.log.isEmpty ? '' : '\nLast lines it printed:\n${exit.log}'}',
    );
  }
}
