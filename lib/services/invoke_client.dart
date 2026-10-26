import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'images/image_catalog.dart';
import 'images/sd_runtime.dart';

/// A model or LoRA installed in Invoke, as its model manager lists it.
class InvokeModel {
  const InvokeModel({
    required this.key,
    required this.hash,
    required this.name,
    required this.base,
    required this.type,
    this.description = '',
    this.triggers = const [],
  });

  factory InvokeModel.fromJson(Map<String, Object?> j) => InvokeModel(
    key: '${j['key']}',
    hash: '${j['hash'] ?? ''}',
    name: '${j['name'] ?? j['key']}',
    base: '${j['base'] ?? ''}',
    type: '${j['type'] ?? ''}',
    description: '${j['description'] ?? ''}',
    triggers: [
      for (final t in (j['trigger_phrases'] as List?) ?? const []) '$t',
    ],
  );

  final String key;
  final String hash;
  final String name;

  /// "sd-1", "sd-2", "sdxl", "flux"…
  final String base;
  final String type;
  final String description;
  final List<String> triggers;

  /// What a graph node takes to name this model.
  Map<String, Object?> get identifier => {
    'key': key,
    'hash': hash,
    'name': name,
    'base': base,
    'type': type,
  };

  /// What the companion is told about this LoRA.
  String get note => [
    if (triggers.isNotEmpty) 'Trigger: ${triggers.join(', ')}.',
    if (description.isNotEmpty)
      description.endsWith('.') ? description : '$description.',
    'For $baseLabel models.',
  ].join(' ');

  String get baseLabel => switch (base) {
    'sd-1' => 'SD 1.5',
    'sd-2' => 'SD 2',
    'sdxl' => 'SDXL',
    _ => base,
  };

  /// An Invoke main model as one of the companion's picture models.
  ImageModel get asImageModel => ImageModel(
    id: '${InvokeClient.idPrefix}$key',
    name: name,
    blurb: description.isEmpty ? 'In your Invoke.' : description,
    style: '$baseLabel in Invoke',
    files: const [],
    prompting: Prompting.both,
    steps: 30,
    cfg: base == 'sdxl' ? 6.0 : 7.0,
    sampler: 'euler_a',
    baseSize: switch (base) {
      'sdxl' => 1024,
      'sd-2' => 768,
      _ => 512,
    },
    own: true,
  );
}

/// Talks to an InvokeAI the human runs (its web API, the one Invoke's own
/// page uses): lists its models and LoRAs, and draws a picture by queueing
/// a small text-to-image graph. Stable Diffusion 1.5, 2 and SDXL models.
class InvokeClient {
  InvokeClient(String baseUrl, {http.Client? client})
    : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
      _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// Picture model ids that name an Invoke model start with this.
  static const idPrefix = 'invoke:';

  /// The model kinds the graph below can draw with.
  static const bases = {'sd-1', 'sd-2', 'sdxl'};

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// Returns Invoke's version string, or null if it can't be reached.
  Future<String?> ping() async {
    try {
      final res = await _http
          .get(_u('/api/v1/app/version'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      return body is Map ? '${body['version'] ?? res.body}' : res.body;
    } catch (_) {
      return null;
    }
  }

  Future<Object?> _get(String path, [Map<String, String>? query]) async {
    final res = await _http
        .get(_u(path, query))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw InvokeException('Invoke answered ${res.statusCode} for $path.');
    }
    return jsonDecode(res.body);
  }

  /// Installed models of [type] ("main" or "lora").
  Future<List<InvokeModel>> models(String type) async {
    final body = await _get('/api/v2/models/', {'model_type': type});
    final list = body is Map ? body['models'] : body;
    return [
      for (final m in (list as List?) ?? const [])
        if (m is Map<String, Object?>) InvokeModel.fromJson(m),
    ];
  }

  /// Main models the companion can draw with, and LoRAs that fit them.
  Future<({List<InvokeModel> models, List<InvokeModel> loras})>
  catalog() async {
    final main = await models('main');
    final loras = await models('lora');
    return (
      models: [
        for (final m in main)
          if (bases.contains(m.base)) m,
      ],
      loras: [
        for (final l in loras)
          if (bases.contains(l.base)) l,
      ],
    );
  }

  /// The text-to-image graph for [model] with [loras] chained between the
  /// model and the prompts.
  static Map<String, Object?> graph({
    required InvokeModel model,
    required String prompt,
    required String negative,
    required int width,
    required int height,
    required int steps,
    required double cfg,
    required String scheduler,
    required int seed,
    List<({InvokeModel lora, double weight})> loras = const [],
  }) {
    final xl = model.base == 'sdxl';
    final nodes = <String, Map<String, Object?>>{
      'model': {
        'id': 'model',
        'type': xl ? 'sdxl_model_loader' : 'main_model_loader',
        'model': model.identifier,
      },
      'positive': {
        'id': 'positive',
        'type': xl ? 'sdxl_compel_prompt' : 'compel',
        'prompt': prompt,
        if (xl) 'style': prompt,
      },
      'negative': {
        'id': 'negative',
        'type': xl ? 'sdxl_compel_prompt' : 'compel',
        'prompt': negative,
        if (xl) 'style': '',
      },
      'noise': {
        'id': 'noise',
        'type': 'noise',
        'seed': seed,
        'width': width,
        'height': height,
        'use_cpu': true,
      },
      'denoise': {
        'id': 'denoise',
        'type': 'denoise_latents',
        'steps': steps,
        'cfg_scale': cfg,
        'scheduler': scheduler,
        'denoising_start': 0,
        'denoising_end': 1,
      },
      'decode': {'id': 'decode', 'type': 'l2i'},
      'save': {'id': 'save', 'type': 'save_image', 'is_intermediate': false},
    };
    final edges = <Map<String, Object?>>[];
    void link(String from, String field, String to, [String? toField]) =>
        edges.add({
          'source': {'node_id': from, 'field': field},
          'destination': {'node_id': to, 'field': toField ?? field},
        });

    // Each LoRA takes the model (and text encoders) from the one before.
    var from = 'model';
    for (final (i, l) in loras.indexed) {
      final id = 'lora$i';
      nodes[id] = {
        'id': id,
        'type': xl ? 'sdxl_lora_loader' : 'lora_loader',
        'lora': l.lora.identifier,
        'weight': l.weight,
      };
      link(from, 'unet', id);
      link(from, 'clip', id);
      if (xl) link(from, 'clip2', id);
      from = id;
    }
    link(from, 'unet', 'denoise');
    for (final side in ['positive', 'negative']) {
      link(from, 'clip', side);
      if (xl) link(from, 'clip2', side);
    }
    link('positive', 'conditioning', 'denoise', 'positive_conditioning');
    link('negative', 'conditioning', 'denoise', 'negative_conditioning');
    link('noise', 'noise', 'denoise');
    link('denoise', 'latents', 'decode');
    link('model', 'vae', 'decode');
    link('decode', 'image', 'save');
    return {'id': 'voxcordis_text2img', 'nodes': nodes, 'edges': edges};
  }

  /// Invoke's scheduler for one of sd-cli's sampler names.
  static String schedulerFor(String sampler) => switch (sampler) {
    'euler' => 'euler',
    'dpm++2m' => 'dpmpp_2m',
    'dpm++2s_a' => 'dpmpp_2s',
    'lcm' => 'lcm',
    _ => 'euler_a',
  };

  /// Draws [r] with [model] and returns the PNG. [cancel] stops it in
  /// Invoke's queue.
  Future<Uint8List> draw(
    DrawRequest r, {
    required InvokeModel model,
    required List<({InvokeModel lora, double weight})> loras,
    required int seed,
    Future<void>? cancel,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final m = r.model;
    final size = r.width != null && r.height != null
        ? (width: r.width!, height: r.height!)
        : m.sizeFor(r.shape);
    final graph = InvokeClient.graph(
      model: model,
      prompt: SdRun.cleanPrompt(r.prompt),
      negative: SdRun.cleanPrompt(r.negative),
      width: size.width,
      height: size.height,
      steps: r.steps ?? m.steps,
      cfg: r.cfg ?? m.cfg,
      scheduler: schedulerFor(m.sampler),
      seed: seed,
      loras: loras,
    );
    final res = await _http
        .post(
          _u('/api/v1/queue/default/enqueue_batch'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'prepend': false,
            'batch': {'graph': graph, 'runs': 1},
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw InvokeException(
        'Invoke didn\'t take the picture (${res.statusCode}): '
        '${_detail(res.body)}',
      );
    }
    final queued = jsonDecode(res.body) as Map;
    final ids = (queued['item_ids'] as List?) ?? const [];
    if (ids.isEmpty) throw InvokeException('Invoke queued nothing.');
    final item = '${ids.first}';
    var stopped = false;
    unawaited(
      cancel?.then((_) async {
        stopped = true;
        try {
          await _http.put(_u('/api/v1/queue/default/i/$item/cancel'));
        } catch (_) {}
      }),
    );
    final until = DateTime.now().add(timeout);
    while (true) {
      if (stopped) throw SdException('Drawing was stopped.');
      if (DateTime.now().isAfter(until)) {
        throw SdException('Drawing took too long and was stopped.');
      }
      final body = await _get('/api/v1/queue/default/i/$item') as Map;
      switch (body['status']) {
        case 'completed':
          final name = _imageIn(body);
          if (name == null) throw InvokeException('Invoke saved no picture.');
          final png = await _http
              .get(_u('/api/v1/images/i/$name/full'))
              .timeout(const Duration(seconds: 60));
          if (png.statusCode != 200) {
            throw InvokeException('Couldn\'t fetch the picture from Invoke.');
          }
          return png.bodyBytes;
        case 'failed':
          throw InvokeException(
            'Invoke couldn\'t draw it: '
            '${body['error_message'] ?? body['error_type'] ?? 'no reason given'}',
          );
        case 'canceled':
          throw SdException('Drawing was stopped.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  /// The saved picture's name in a finished queue item.
  static String? _imageIn(Map item) {
    final results = (item['session'] as Map?)?['results'] as Map?;
    for (final out in results?.values ?? const []) {
      final name = (out is Map ? out['image'] as Map? : null)?['image_name'];
      if (name != null) return '$name';
    }
    return null;
  }

  static String _detail(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] != null) return '${j['detail']}';
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}

class InvokeException implements Exception {
  InvokeException(this.message);
  final String message;
  @override
  String toString() => message;
}
