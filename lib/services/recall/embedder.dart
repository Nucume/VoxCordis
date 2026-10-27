import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../data/recall/recall_index.dart';
import '../llm_client.dart';
import '../runtime/llama_server.dart';
import '../runtime/model_catalog.dart';

/// Turns texts into unit vectors that are close when the texts mean
/// similar things.
abstract class TextEmbedder {
  /// Names the model, so vectors it made are told apart from another's.
  String get model;

  /// One vector per text, in order. [query] marks what is being looked
  /// for, as against the texts being looked through.
  Future<List<Float32List>> embed(List<String> texts, {required bool query});
}

/// [TextEmbedder] on Recall's llama-server (EmbeddingGemma).
class Embedder implements TextEmbedder {
  Embedder({required this.target, http.Client? client})
    : _http = client ?? http.Client();

  /// Where the embedding server is, started if need be.
  final Future<({String baseUrl, String apiKey})> Function() target;
  final http.Client _http;

  /// Tokens the model reads at most, and about the characters that is;
  /// longer texts are cut.
  static const contextSize = 2048;
  static const maxChars = 6000;

  /// Texts embedded in one request.
  static const batch = 8;

  /// EmbeddingGemma's prompts: one for what is searched for, one for the
  /// texts searched through.
  static const queryPrefix = 'task: search result | query: ';
  static const documentPrefix = 'title: none | text: ';

  @override
  String get model => ModelCatalog.recall.id;

  @override
  Future<List<Float32List>> embed(
    List<String> texts, {
    required bool query,
  }) async {
    final out = <Float32List>[];
    for (var i = 0; i < texts.length; i += batch) {
      final part = texts.sublist(i, (i + batch).clamp(0, texts.length));
      try {
        out.addAll(await _embed(part, query: query));
      } on LlmException {
        // One text the server won't take (too many tokens for its
        // context, say) must not stop the rest: each goes alone, cut
        // shorter until it fits.
        if (part.length == 1) rethrow;
        for (final text in part) {
          out.add(await _one(text, query: query));
        }
      }
    }
    return out;
  }

  Future<Float32List> _one(String text, {required bool query}) async {
    var t = text;
    while (true) {
      try {
        return (await _embed([t], query: query)).single;
      } on LlmException {
        if (t.length <= 500) rethrow;
        t = t.substring(0, t.length ~/ 2);
      }
    }
  }

  Future<List<Float32List>> _embed(
    List<String> texts, {
    required bool query,
  }) async {
    final t = await target();
    final res = await _http
        .post(
          Uri.parse('${t.baseUrl.replaceAll(RegExp(r'/+$'), '')}/embeddings'),
          headers: {
            'Content-Type': 'application/json',
            if (t.apiKey.isNotEmpty) 'Authorization': 'Bearer ${t.apiKey}',
          },
          body: jsonEncode({
            'model': LlamaServer.modelAlias,
            'input': [for (final text in texts) prepare(text, query: query)],
          }),
        )
        .timeout(const Duration(minutes: 2));
    if (res.statusCode != 200) {
      throw LlmException('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = (jsonDecode(res.body) as Map)['data'] as List;
    if (data.length != texts.length) {
      throw LlmException(
        'Got ${data.length} vectors for ${texts.length} texts',
      );
    }
    final byIndex = List<Float32List?>.filled(texts.length, null);
    for (final (i, d) in data.indexed) {
      final m = d as Map;
      final at = (m['index'] as int?) ?? i;
      byIndex[at] = RecallIndex.normalize((m['embedding'] as List).cast<num>());
    }
    return [for (final v in byIndex) v!];
  }

  /// [text] as sent to the model: cut to [maxChars] and prefixed.
  static String prepare(String text, {required bool query}) {
    final t = text.trim().replaceAll(RegExp(r'[ \t]+'), ' ');
    final cut = t.length <= maxChars ? t : t.substring(0, maxChars);
    return '${query ? queryPrefix : documentPrefix}$cut';
  }
}
