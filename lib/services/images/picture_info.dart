import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'sd_runtime.dart';

/// What a picture was drawn with: the words, model and numbers, so it can
/// be looked up (and drawn again) later. Kept beside the picture in a
/// hidden `.info` folder as `<picture file name>.json`.
class PictureInfo {
  const PictureInfo({
    required this.prompt,
    this.negative = '',
    required this.model,
    required this.seed,
    required this.width,
    required this.height,
    this.steps,
    this.cfg,
    this.sampler,
    this.scheduler,
    this.loras = const [],
    this.invoke = false,
    this.made,
  });

  final String prompt;
  final String negative;

  /// The model's name as shown in the app.
  final String model;
  final int seed;
  final int width;
  final int height;
  final int? steps;
  final double? cfg;

  /// The names shown in the app ("Euler a", "Karras").
  final String? sampler;
  final String? scheduler;
  final List<({String name, double weight})> loras;

  /// Drawn in Invoke rather than the built-in drawing.
  final bool invoke;
  final DateTime? made;

  /// What [r] was drawn with at [seed]: the model's own numbers where the
  /// request left them out.
  static PictureInfo of(DrawRequest r, int seed, {bool invoke = false}) {
    final m = r.model;
    final size = r.width != null && r.height != null
        ? (width: r.width!, height: r.height!)
        : m.sizeFor(r.shape);
    final sampler = SdRun.samplers.containsKey(r.sampler)
        ? r.sampler!
        : m.sampler;
    final scheduler = SdRun.schedulers.containsKey(r.scheduler)
        ? r.scheduler
        : m.scheduler;
    return PictureInfo(
      prompt: r.prompt,
      negative: r.negative,
      model: m.name,
      seed: seed,
      width: size.width,
      height: size.height,
      steps: r.steps ?? m.steps,
      cfg: r.cfg ?? m.cfg,
      sampler: invoke ? null : SdRun.samplers[sampler] ?? sampler,
      scheduler: invoke || scheduler == null
          ? null
          : SdRun.schedulers[scheduler] ?? scheduler,
      loras: r.loras,
      invoke: invoke,
      made: DateTime.now(),
    );
  }

  /// Where [picture]'s info is kept.
  static File fileFor(File picture) => File(
    p.join(picture.parent.path, '.info', '${p.basename(picture.path)}.json'),
  );

  /// [picture]'s info, or null when it has none (added by hand, drawn
  /// before this was kept, or unreadable).
  static Future<PictureInfo?> read(File picture) async {
    try {
      final f = fileFor(picture);
      if (!await f.exists()) return null;
      return fromJson(jsonDecode(await f.readAsString()));
    } on Object {
      return null;
    }
  }

  /// Keeps this as [picture]'s info; a failure is ignored, the picture
  /// matters more.
  Future<void> writeFor(File picture) async {
    try {
      final f = fileFor(picture);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(toJson()));
    } on Object {
      // Only the notes.
    }
  }

  /// Removes [picture]'s info, with the picture.
  static Future<void> deleteFor(File picture) async {
    try {
      final f = fileFor(picture);
      if (await f.exists()) await f.delete();
    } on Object {
      // Only the notes.
    }
  }

  /// Moves [from]'s info along to [to].
  static Future<void> move(File from, File to) async {
    final info = await read(from);
    if (info == null) return;
    await info.writeFor(to);
    await deleteFor(from);
  }

  /// Every part as a line, the way it is shown and copied.
  List<(String, String)> get lines => [
    ('Prompt', prompt),
    if (negative.trim().isNotEmpty) ('Negative', negative),
    ('Model', invoke ? '$model (Invoke)' : model),
    ('Seed', '$seed'),
    ('Size', '$width x $height'),
    if (steps != null) ('Steps', '$steps'),
    if (cfg != null) ('Guidance', '$cfg'),
    if (sampler != null) ('Sampler', sampler!),
    if (scheduler != null) ('Scheduler', scheduler!),
    if (loras.isNotEmpty)
      ('LoRAs', loras.map((l) => '${l.name} ${l.weight}').join(', ')),
  ];

  /// Everything as plain text, to copy.
  String get text => [for (final (k, v) in lines) '$k: $v'].join('\n');

  Map<String, Object?> toJson() => {
    'v': 1,
    'prompt': prompt,
    if (negative.isNotEmpty) 'negative': negative,
    'model': model,
    'seed': seed,
    'width': width,
    'height': height,
    'steps': ?steps,
    'cfg': ?cfg,
    'sampler': ?sampler,
    'scheduler': ?scheduler,
    if (loras.isNotEmpty)
      'loras': [
        for (final l in loras) {'name': l.name, 'weight': l.weight},
      ],
    if (invoke) 'invoke': true,
    'made': ?made?.toIso8601String(),
  };

  static PictureInfo? fromJson(Object? json) {
    if (json is! Map || json['prompt'] is! String) return null;
    num? n(Object? v) => v is num ? v : null;
    return PictureInfo(
      prompt: json['prompt']! as String,
      negative: json['negative'] is String ? json['negative']! as String : '',
      model: json['model'] is String ? json['model']! as String : '',
      seed: n(json['seed'])?.toInt() ?? 0,
      width: n(json['width'])?.toInt() ?? 0,
      height: n(json['height'])?.toInt() ?? 0,
      steps: n(json['steps'])?.toInt(),
      cfg: n(json['cfg'])?.toDouble(),
      sampler: json['sampler'] as String?,
      scheduler: json['scheduler'] as String?,
      loras: [
        if (json['loras'] is List)
          for (final l in json['loras'] as List)
            if (l is Map && l['name'] is String)
              (
                name: l['name']! as String,
                weight: n(l['weight'])?.toDouble() ?? 1,
              ),
      ],
      invoke: json['invoke'] == true,
      made: json['made'] is String
          ? DateTime.tryParse(json['made']! as String)
          : null,
    );
  }
}
