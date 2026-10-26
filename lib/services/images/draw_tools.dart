import 'dart:convert';

import '../../data/settings.dart';
import 'image_catalog.dart';
import 'image_engine.dart';
import 'sd_runtime.dart';

/// draw_picture: the companion asks for a picture and picks the model,
/// LoRAs, prompt and shape itself. It is drawn after the reply, so the
/// reply isn't held up and the picture model can have the graphics card.
class DrawTools {
  DrawTools({required this.settings, required this.engine});

  final AppSettings Function() settings;
  final ImageEngine engine;

  static const drawTool = 'draw_picture';
  static const names = {drawTool};

  /// More than this many waiting would be a model stuck in a loop.
  static const maxWaiting = 4;

  static List<Map<String, Object?>> definitionsFor(AppSettings s) => [
    if (s.imageEngine != ImageEngineChoice.off)
      {
        'type': 'function',
        'function': {
          'name': drawTool,
          'description':
              'Draw a picture for your human. It appears in the chat a '
              'little after your reply, so say you are drawing it.',
          'parameters': {
            'type': 'object',
            'properties': {
              'prompt': {
                'type': 'string',
                'description':
                    'What to draw, written the way the model likes (see '
                    '"Drawing").',
              },
              'negative_prompt': {
                'type': 'string',
                'description': 'What to keep out of the picture.',
              },
              'model': {
                'type': 'string',
                'description': 'One of your picture models, by name.',
              },
              'shape': {
                'type': 'string',
                'enum': ['square', 'portrait', 'landscape'],
              },
              'loras': {
                'type': 'array',
                'description': 'LoRAs to use, by name, each with a weight.',
                'items': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string'},
                    'weight': {
                      'type': 'number',
                      'description': 'Usually 0.6 to 1.',
                    },
                  },
                  'required': ['name'],
                },
              },
            },
            'required': ['prompt'],
          },
        },
      },
  ];

  /// Runs one tool call and returns the JSON string sent back to the model.
  Future<String> call(String name, Map<String, Object?> args) async {
    try {
      if (name != drawTool) throw 'unknown tool $name';
      final s = settings();
      final folder = s.companionFolder;
      if (folder == null) throw 'there is no folder yet';
      if (s.imageEngine == ImageEngineChoice.off) {
        throw 'drawing is off. Your human can turn it on in Settings → Images.';
      }
      var ready = engine.available(s);
      if (ready.isEmpty && s.imageEngine == ImageEngineChoice.invoke) {
        await engine.refreshInvoke(s);
        ready = engine.available(s);
      }
      if (ready.isEmpty) {
        throw s.imageEngine == ImageEngineChoice.invoke
            ? 'Invoke isn\'t answering or has no Stable Diffusion model. '
                  'Your human can check it in Settings → Images.'
            : 'there is no picture model yet. Your human can download one '
                  'in Settings → Images.';
      }
      final prompt = SdRun.cleanPrompt('${args['prompt'] ?? ''}');
      if (prompt.isEmpty) throw 'say what to draw in prompt';
      if (engine.waiting >= maxWaiting) {
        throw 'there are already $maxWaiting pictures waiting to be drawn';
      }
      final wanted = '${args['model'] ?? ''}'.trim().toLowerCase();
      final model = wanted.isEmpty
          ? ImageCatalog.defaultFor(s, ready)!
          : ready.where((m) => _matches(m, wanted)).firstOrNull;
      if (model == null) {
        throw 'there is no picture model "$wanted". You have: '
            '${ready.map(nameFor).join(', ')}.';
      }
      final known = {
        for (final l in engine.lorasFor(s)) l.name.toLowerCase(): l.name,
      };
      final loras = <({String name, double weight})>[];
      for (final l in (args['loras'] as List?) ?? const []) {
        final raw = l is Map ? '${l['name'] ?? ''}' : '$l';
        final real = known[raw.trim().toLowerCase()];
        if (real == null) {
          throw 'there is no LoRA "$raw". You have: '
              '${known.isEmpty ? 'none' : known.values.join(', ')}.';
        }
        final w = l is Map ? l['weight'] : null;
        loras.add((
          name: real,
          weight: (w is num ? w.toDouble() : 0.8).clamp(-2.0, 2.0),
        ));
      }
      final shape = '${args['shape'] ?? 'square'}';
      engine.draw(
        DrawJob(
          DrawRequest(
            model: model,
            prompt: prompt,
            negative: '${args['negative_prompt'] ?? ''}',
            shape: const {'portrait', 'landscape'}.contains(shape)
                ? shape
                : 'square',
            loras: loras.take(4).toList(),
          ),
          folder: folder,
        ),
      );
      return jsonEncode({
        'ok': true,
        'drawing': nameFor(model),
        'note':
            'It is drawn after your reply and shows up in the chat by '
            'itself. Don\'t describe it as finished yet.',
      });
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  /// The name the companion uses for [m]: the catalog id, or the human's
  /// file name without its extension.
  static String nameFor(ImageModel m) => m.own ? m.name : m.id;

  static bool _matches(ImageModel m, String wanted) =>
      m.id.toLowerCase() == wanted ||
      m.name.toLowerCase() == wanted ||
      nameFor(m).toLowerCase() == wanted;
}

/// What the companion is told about drawing.
String aboutDrawing(
  AppSettings s,
  List<ImageModel> ready,
  List<({String name, String note})> loras,
) {
  if (s.imageEngine == ImageEngineChoice.off || ready.isEmpty) {
    return '## Drawing\n'
        'You can\'t draw pictures yet. If your human asks for one, tell them '
        'they can set up drawing in Settings → Images, and never pretend you '
        'drew something.';
  }
  final main = ImageCatalog.defaultFor(s, ready)!;
  final b = StringBuffer(
    '## Drawing\n'
    'You can draw pictures with draw_picture: when your human asks for '
    'one, when they would enjoy one, or to show yourself (your looks are in '
    'personality.md). Pick the model and LoRAs that suit, and write the '
    'prompt the way that model likes. Quality tags are added for you.\n'
    'Your picture models:\n',
  );
  for (final m in ready) {
    b.write(
      '- ${DrawTools.nameFor(m)}${m == main ? ' (your usual one)' : ''}: '
      '${m.style}; write ${m.promptingHint}.\n',
    );
  }
  if (loras.isNotEmpty) {
    b.write('Your LoRAs (styles, characters or details to add):\n');
    for (final l in loras.take(30)) {
      final note = l.note.length > 160
          ? '${l.note.substring(0, 160)}…'
          : l.note;
      b.write('- ${l.name}${note.isEmpty ? '' : ': $note'}\n');
    }
  }
  return b.toString().trimRight();
}
