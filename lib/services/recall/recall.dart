import 'dart:async';

import '../../data/memory/memory.dart';
import '../../data/memory/memory_repository.dart';
import '../../data/message_repository.dart';
import '../../data/recall/recall_index.dart';
import '../logs/app_log.dart';
import 'embedder.dart';

/// An exchange from earlier in the chat that fits what is being said now:
/// the human's message and the reply it got.
class Moment {
  const Moment({required this.said, this.reply, required this.score});

  final ChatMessage said;
  final ChatMessage? reply;
  final double score;
}

/// What goes into a prompt from memory.
class Recalled {
  const Recalled({
    required this.memories,
    this.moments = const [],
    required this.byMeaning,
  });

  final List<Memory> memories;
  final List<Moment> moments;

  /// Whether Recall found them by meaning, or words were matched because
  /// Recall isn't downloaded or didn't answer.
  final bool byMeaning;
}

/// Finds memories and older chat by meaning, with the Recall embedding
/// model, and keeps their vectors up to date in the background. Without
/// Recall it falls back to matching words.
class Recall {
  Recall({
    required this.index,
    required this.memories,
    required this.messages,
    required this.embedder,
    required this.available,
    this.paused,
    this.log,
  });

  /// The current companion's index and tables; they change when the human
  /// switches companion.
  final RecallIndex Function() index;
  final MemoryRepository Function() memories;
  final MessageRepository Function() messages;
  final TextEmbedder embedder;

  /// Whether Recall is downloaded.
  final bool Function() available;

  /// While this is true the background indexing waits: a reply is being
  /// written and the embedding server should answer that first.
  final bool Function()? paused;
  final AppLog? log;

  /// How alike a memory, or a moment, has to be to what was said to come
  /// up at all. Cosines of EmbeddingGemma vectors: texts about different
  /// things sit around 0.3, the same thing in other words above 0.5.
  static const memoryMinScore = 0.4;
  static const momentMinScore = 0.45;

  /// What is put in the prompt for [query]: the top [pinned] memories by
  /// priority, up to [related] more that fit by meaning, and up to
  /// [moments] exchanges from before [beforeSortOrder] (the recent turns
  /// that are in the prompt anyway). Bumps `reinforced_count` on the
  /// related memories.
  Future<Recalled> recall(
    String query, {
    int pinned = 8,
    int related = 8,
    int moments = 3,
    int? beforeSortOrder,
  }) async {
    final repo = memories();
    if (!available() || query.trim().isEmpty) {
      return Recalled(
        memories: await repo.recall(query, pinned: pinned, related: related),
        byMeaning: false,
      );
    }
    try {
      final q = (await embedder.embed([query], query: true)).single;
      final idx = index();
      final model = embedder.model;
      final top = await repo.pinned(pinned);
      final seen = {for (final m in top) m.id};
      final hits = await idx.search(
        RecallIndex.memoryKind,
        model,
        q,
        limit: related + pinned,
        minScore: memoryMinScore,
      );
      final ids = [
        for (final h in hits)
          if (!seen.contains(h.id)) h.id,
      ].take(related).toList();
      final found = await repo.byIds(ids);
      await repo.reinforce(ids);

      final out = <Moment>[];
      if (moments > 0) {
        final hits = await idx.search(
          RecallIndex.momentKind,
          model,
          q,
          limit: moments * 4,
          minScore: momentMinScore,
        );
        final said = {
          for (final m in await messages().byIds([for (final h in hits) h.id]))
            m.id: m,
        };
        for (final h in hits) {
          final u = said[h.id];
          if (u == null) continue;
          if (beforeSortOrder != null && u.sortOrder >= beforeSortOrder) {
            continue;
          }
          out.add(
            Moment(said: u, reply: await messages().replyTo(u), score: h.score),
          );
          if (out.length == moments) break;
        }
      }
      return Recalled(
        memories: [...top, ...found],
        moments: out,
        byMeaning: true,
      );
    } on Object catch (e) {
      log?.add(
        LogKind.errors,
        'Recall couldn\'t search by meaning, so words were matched instead',
        details: '$e',
        error: true,
      );
      return Recalled(
        memories: await repo.recall(query, pinned: pinned, related: related),
        byMeaning: false,
      );
    }
  }

  Future<void>? _indexing;
  bool _again = false;
  final _refresh = <String>{};

  /// Embeds what has no vector yet: new memories, and exchanges whose
  /// reply is in. Runs in the background, one pass at a time, [limit]
  /// exchanges at most (null for everything, after start or an import).
  /// [refresh] is a human message whose exchange changed (a new reply) and
  /// is embedded again.
  Future<void> update({int? limit, String? refresh}) {
    if (refresh != null) _refresh.add(refresh);
    if (!available()) return Future.value();
    if (_indexing case final running?) {
      _again = true;
      return running;
    }
    return _indexing = _pass(limit).whenComplete(() {
      _indexing = null;
      if (_again) {
        _again = false;
        update(limit: limit).ignore();
      }
    });
  }

  /// Whether a pass is running.
  bool get indexing => _indexing != null;

  Future<void> _pass(int? limit) async {
    final idx = index();
    final model = embedder.model;
    var budget = limit;
    try {
      await idx.sweep();
      if (_refresh.isNotEmpty) {
        await idx.remove(RecallIndex.momentKind, _refresh.toList());
        _refresh.clear();
      }
      while (true) {
        if (!identical(idx, index())) return; // another companion now
        if (paused?.call() ?? false) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final facts = await idx.memoriesWithout(model, limit: Embedder.batch);
        if (facts.isNotEmpty) {
          final vectors = await embedder.embed([
            for (final m in facts) m.text,
          ], query: false);
          await idx.putAll(RecallIndex.memoryKind, model, {
            for (final (i, m) in facts.indexed) m.id: vectors[i],
          });
          continue;
        }
        final said = await idx.momentsWithout(model, limit: Embedder.batch + 1);
        // The newest message waiting for its reply is embedded once the
        // reply is in.
        final last = (await messages().recent(limit: 1)).firstOrNull;
        final ready = [
          for (final m in said)
            if (m.id != last?.id || last?.role != 'user') m,
        ].take(Embedder.batch).toList();
        if (ready.isEmpty) break;
        final texts = <String>[];
        for (final m in ready) {
          texts.add(momentText(m, await messages().replyTo(m)));
        }
        final vectors = await embedder.embed(texts, query: false);
        await idx.putAll(RecallIndex.momentKind, model, {
          for (final (i, m) in ready.indexed) m.id: vectors[i],
        });
        if (budget != null) {
          budget -= ready.length;
          if (budget <= 0) break;
        }
        // Let the chat and the rest of the app breathe between batches.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } on Object catch (e) {
      log?.add(
        LogKind.errors,
        'Recall couldn\'t index memories and chat',
        details: '$e',
        error: true,
      );
    }
  }

  /// An exchange as it is embedded: both sides, each cut so the whole
  /// fits what the model reads.
  static String momentText(ChatMessage said, ChatMessage? reply) {
    String cut(String s) => s.length <= Embedder.maxChars ~/ 2
        ? s
        : s.substring(0, Embedder.maxChars ~/ 2);
    final r = reply?.content.trim() ?? '';
    return r.isEmpty
        ? cut(said.content.trim())
        : '${cut(said.content.trim())}\n\n${cut(r)}';
  }
}
