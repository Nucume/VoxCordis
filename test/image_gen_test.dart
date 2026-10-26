import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/images/draw_tools.dart';
import 'package:companion/services/images/image_catalog.dart';
import 'package:companion/services/images/image_engine.dart';
import 'package:companion/services/images/sd_runtime.dart';
import 'package:companion/services/invoke_client.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A stand-in for sd-cli: prints progress like it, saves a small PNG where
/// -o says, and writes its arguments down for the test to read.
Future<String> _fakeSdCli(Directory dir) async {
  final png = File(p.join(dir.path, 'fixture.png'))
    ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
  final script = File(p.join(dir.path, 'sd-cli'))
    ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" > "${dir.path}/args.txt"
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then out="\$2"; fi
  shift
done
printf '\\r|==>   | 1/2 - 1.00s/it\\r|=====| 2/2 - 1.00s/it\\n'
cp "${png.path}" "\$out"
''');
  await Process.run('chmod', ['+x', script.path]);
  return script.path;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('draw'));
  tearDown(() => tmp.delete(recursive: true));

  test('picks the sd-cli build for each computer', () {
    expect(
      SdInstaller.buildFor(os: 'linux', arm: false, gpu: true),
      'linux-vulkan',
    );
    expect(
      SdInstaller.buildFor(os: 'linux', arm: false, gpu: false),
      'linux-cpu',
    );
    expect(
      SdInstaller.buildFor(os: 'windows', arm: false, gpu: true),
      'windows-vulkan',
    );
    expect(
      SdInstaller.buildFor(os: 'macos', arm: true, gpu: false),
      'macos-arm64',
    );
    expect(SdInstaller.buildFor(os: 'macos', arm: false, gpu: true), isNull);
    for (final b in SdInstaller.builds.values) {
      expect(b.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
  });

  test('every catalog file is pinned', () {
    for (final m in ImageCatalog.models) {
      for (final f in m.files) {
        expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.path);
        expect(f.revision, matches(RegExp(r'^[0-9a-f]{40}$')), reason: f.path);
      }
      expect(
        m.files.where((f) => f.role.name == 'checkpoint').length +
            m.files.where((f) => f.role.name == 'diffusion').length,
        1,
      );
    }
  });

  test('builds sd-cli arguments from the model card', () {
    final anima = ImageCatalog.byId('anima-turbo')!;
    final args = SdRun.args(
      DrawRequest(
        model: anima,
        prompt: '1girl, <lora:/etc/passwd:1> smile\nnight',
        shape: 'portrait',
        loras: const [(name: 'watercolor', weight: 0.7)],
      ),
      modelsDir: Directory('/m'),
      lorasDir: Directory('/l'),
      out: File('/o/x.png'),
      seed: 42,
    );
    String after(String flag) => args[args.indexOf(flag) + 1];
    expect(after('--diffusion-model'), '/m/anima-turbo-v1.1.safetensors');
    expect(after('--vae'), '/m/qwen_image_vae.safetensors');
    expect(after('--llm'), '/m/qwen_3_06b_base.safetensors');
    expect(
      after('-p'),
      'masterpiece, best quality, 1girl, smile night <lora:watercolor:0.7>',
    );
    expect(after('--cfg-scale'), '1.0');
    expect(after('--steps'), '10');
    expect(after('-W'), '832');
    expect(after('-H'), '1216');
    expect(after('-s'), '42');
    expect(after('--lora-model-dir'), '/l');
    expect(args, isNot(contains('-n')));

    final realvis = SdRun.args(
      DrawRequest(
        model: ImageCatalog.byId('realvisxl-5')!,
        prompt: 'a lighthouse',
        negative: 'fog',
        shape: 'landscape',
      ),
      modelsDir: Directory('/m'),
      lorasDir: Directory('/l'),
      out: File('/o/x.png'),
      seed: 1,
    );
    expect(
      realvis[realvis.indexOf('-m') + 1],
      '/m/RealVisXL_V5.0_fp16.safetensors',
    );
    expect(realvis[realvis.indexOf('-n') + 1], startsWith('fog, bad hands'));
    expect(realvis[realvis.indexOf('--scheduler') + 1], 'karras');
    expect(realvis[realvis.indexOf('-W') + 1], '1216');
    expect(realvis, isNot(contains('--lora-model-dir')));

    expect(SdRun.progressIn('\r|==>  | 5/20 - 1.23s/it'), (step: 5, steps: 20));
    expect(SdRun.progressIn('loading model'), isNull);
  });

  test('finds the human\'s own models and LoRAs', () async {
    final s = AppSettings(modelsFolder: tmp.path);
    final dir = ImageCatalog.dirFor(s)..createSync(recursive: true);
    File(p.join(dir.path, 'myMix.safetensors')).writeAsStringSync('x');
    // A part of a catalog model is not one of the human's own.
    File(p.join(dir.path, 'qwen_image_vae.safetensors')).writeAsStringSync('x');
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('x');
    final own = ImageCatalog.own(dir);
    expect(own.map((m) => m.id), ['myMix.safetensors']);
    expect(own.single.baseSize, 512, reason: 'a small file is an SD 1.5 model');
    expect(ImageCatalog.available(dir).single.own, isTrue);

    final loras = ImageCatalog.lorasFor(s)..createSync(recursive: true);
    File(p.join(loras.path, 'Watercolor.safetensors')).writeAsStringSync('x');
    File(
      p.join(loras.path, 'Watercolor.txt'),
    ).writeAsStringSync('Trigger: wtrcolor\nsoft painted look');
    File(p.join(loras.path, 'bad:name.safetensors')).writeAsStringSync('x');
    expect(ImageCatalog.loras(loras), [
      (name: 'Watercolor', note: 'Trigger: wtrcolor soft painted look'),
    ]);

    final text = aboutDrawing(
      s.copyWith(imageEngine: ImageEngineChoice.builtIn),
      ImageCatalog.available(dir),
      ImageCatalog.loras(loras),
    );
    expect(text, contains('- myMix (your usual one)'));
    expect(text, contains('- Watercolor: Trigger: wtrcolor'));
    expect(
      aboutDrawing(s, const [], const []),
      contains('can\'t draw pictures yet'),
    );
  });

  test('the companion asks for a picture, and it is drawn after', () async {
    final folder = p.join(tmp.path, 'Mira');
    var settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
      modelsFolder: tmp.path,
      llmMode: LlmMode.external,
    );
    final runtime = RuntimeController(tmp);
    final exe = await _fakeSdCli(tmp);
    final engine = ImageEngine(
      supportDir: tmp,
      runtime: runtime,
      settings: () => settings,
      findExe: (_) async => exe,
    );
    final tools = DrawTools(settings: () => settings, engine: engine);
    Future<Map> draw(Map<String, Object?> args) async =>
        jsonDecode(await tools.call('draw_picture', args)) as Map;

    expect((await draw({'prompt': 'a cat'}))['error'], contains('off'));
    settings = settings.copyWith(imageEngine: ImageEngineChoice.builtIn);
    expect(
      (await draw({'prompt': 'a cat'}))['error'],
      contains('no picture model'),
    );

    final dir = ImageCatalog.dirFor(settings)..createSync(recursive: true);
    File(p.join(dir.path, 'mine.safetensors')).writeAsStringSync('x');
    expect(
      (await draw({'prompt': 'a cat', 'model': 'sdxl'}))['error'],
      contains('You have: mine'),
    );
    expect(
      (await draw({
        'prompt': 'a cat',
        'loras': [
          {'name': 'nope'},
        ],
      }))['error'],
      contains('no LoRA'),
    );

    final drawn = <File>[];
    engine.onDrawn = (job, file) async => drawn.add(file);
    final ok = await draw({'prompt': 'a cat', 'shape': 'portrait'});
    expect(ok['ok'], isTrue);
    expect(ok['drawing'], 'mine');
    while (engine.busy || engine.waiting > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(drawn.single.existsSync(), isTrue);
    expect(p.isWithin(p.join(folder, 'images'), drawn.single.path), isTrue);
    final args = File(p.join(tmp.path, 'args.txt')).readAsLinesSync();
    expect(args[args.indexOf('-m') + 1], p.join(dir.path, 'mine.safetensors'));
    expect(args[args.indexOf('-H') + 1], '640');
  });

  test(
    'a drawn picture lands in the chat, and the companion remembers it',
    () async {
      final requests = <Map>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requests.add(jsonDecode(await utf8.decodeStream(req)) as Map);
        req.response.headers.contentType = ContentType('text', 'event-stream');
        final delta = requests.length == 1
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'function': {
                      'name': 'draw_picture',
                      'arguments': '{"prompt": "a red fox in snow"}',
                    },
                  },
                ],
              }
            : {'content': 'Drawing it now!'};
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'delta': delta},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await req.response.close();
      });
      final db = await openAppDatabase(inMemoryDatabasePath);
      final folder = p.join(tmp.path, 'Mira');
      final services = AppServices(
        settings: SettingsStore(
          File(p.join(tmp.path, 'settings.json')),
          AppSettings(
            companionName: 'Mira',
            companionFolder: folder,
            modelsFolder: tmp.path,
            llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
            llmMode: LlmMode.external,
            llmModel: 'mock',
            imageEngine: ImageEngineChoice.builtIn,
          ),
        ),
        db: db,
        dbKey: DatabaseKey(Directory.systemTemp),
        runtime: RuntimeController(tmp),
      );
      addTearDown(() async {
        await server.close(force: true);
        await db.close();
      });
      final dir = ImageCatalog.dirFor(services.settings.value)
        ..createSync(recursive: true);
      File(p.join(dir.path, 'mine.safetensors')).writeAsStringSync('x');
      final exe = await _fakeSdCli(tmp);
      final chat = ChatController(services);
      services.imageEngine
        ..findExe = ((_) async => exe)
        ..onDrawn = chat.addPicture;

      await chat.send('Draw me a fox?');
      expect(chat.error, isNull);
      expect(chat.toolNote, 'Drawing a picture');
      final system =
          ((requests.first['messages'] as List).first as Map)['content']
              as String;
      expect(system, contains('- mine (your usual one)'));
      while (chat.messages.last.via != 'picture') {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(chat.messages.last.content, startsWith('[image: images/drawn-'));

      await chat.send('What did you draw?');
      final history = requests.last['messages'] as List;
      expect(
        history.map((m) => (m as Map)['content']).join('\n'),
        contains('A picture you drew: images/drawn-'),
      );
      expect(
        history.map((m) => (m as Map)['content']).join('\n'),
        contains('What you asked for: a red fox in snow'),
      );
    },
  );

  test('builds an Invoke graph with LoRAs chained in', () {
    const xl = InvokeModel(
      key: 'k1',
      hash: 'h',
      name: 'Juggernaut',
      base: 'sdxl',
      type: 'main',
    );
    const lora = InvokeModel(
      key: 'l1',
      hash: 'h',
      name: 'Ink',
      base: 'sdxl',
      type: 'lora',
    );
    final g = InvokeClient.graph(
      model: xl,
      prompt: 'a fox',
      negative: 'text',
      width: 832,
      height: 1216,
      steps: 30,
      cfg: 6,
      scheduler: 'euler_a',
      seed: 7,
      loras: const [(lora: lora, weight: 0.7)],
    );
    final nodes = g['nodes'] as Map;
    expect((nodes['model'] as Map)['type'], 'sdxl_model_loader');
    expect((nodes['lora0'] as Map)['type'], 'sdxl_lora_loader');
    expect((nodes['lora0'] as Map)['weight'], 0.7);
    String? into(String node, String field) {
      for (final e in g['edges'] as List) {
        final d = (e as Map)['destination'] as Map;
        if (d['node_id'] == node && d['field'] == field) {
          return (e['source'] as Map)['node_id'] as String;
        }
      }
      return null;
    }

    expect(into('lora0', 'clip2'), 'model');
    expect(into('denoise', 'unet'), 'lora0');
    expect(into('positive', 'clip2'), 'lora0');
    expect(into('decode', 'vae'), 'model');
    expect(into('save', 'image'), 'decode');
  });

  test('draws through Invoke with what Invoke has', () async {
    final posted = <Map>[];
    final png = img.encodePng(img.Image(width: 4, height: 4));
    var polls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      final body = await utf8.decodeStream(req);
      Object? answer;
      if (path == '/api/v2/models/') {
        answer = {
          'models': req.uri.queryParameters['model_type'] == 'lora'
              ? [
                  {
                    'key': 'l1',
                    'hash': 'x',
                    'name': 'Ink',
                    'base': 'sd-1',
                    'type': 'lora',
                    'trigger_phrases': ['inkstyle'],
                  },
                ]
              : [
                  {
                    'key': 'm1',
                    'hash': 'x',
                    'name': 'Dreamshaper',
                    'base': 'sd-1',
                    'type': 'main',
                  },
                  {
                    'key': 'f1',
                    'hash': 'x',
                    'name': 'FLUX dev',
                    'base': 'flux',
                    'type': 'main',
                  },
                ],
        };
      } else if (path == '/api/v1/queue/default/enqueue_batch') {
        posted.add(jsonDecode(body) as Map);
        answer = {
          'item_ids': [5],
        };
      } else if (path == '/api/v1/queue/default/i/5') {
        answer = ++polls < 2
            ? {'status': 'in_progress'}
            : {
                'status': 'completed',
                'session': {
                  'results': {
                    'x': {
                      'type': 'image_output',
                      'image': {'image_name': 'abc.png'},
                    },
                  },
                },
              };
      } else if (path == '/api/v1/images/i/abc.png/full') {
        req.response.add(png);
        await req.response.close();
        return;
      }
      if (answer == null) req.response.statusCode = 404;
      req.response.write(jsonEncode(answer ?? {'detail': 'nope'}));
      await req.response.close();
    });

    final folder = p.join(tmp.path, 'Mira');
    final settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
      modelsFolder: tmp.path,
      llmMode: LlmMode.external,
      imageEngine: ImageEngineChoice.invoke,
      invokeUrl: 'http://127.0.0.1:${server.port}/',
    );
    final engine = ImageEngine(
      supportDir: tmp,
      runtime: RuntimeController(tmp),
      settings: () => settings,
    );
    final tools = DrawTools(settings: () => settings, engine: engine);
    final ok =
        jsonDecode(
              await tools.call('draw_picture', {
                'prompt': 'a lighthouse',
                'loras': [
                  {'name': 'ink', 'weight': 0.5},
                ],
              }),
            )
            as Map;
    expect(ok['ok'], isTrue, reason: '$ok');
    expect(ok['drawing'], 'Dreamshaper');
    expect(engine.available(settings).map((m) => m.name), ['Dreamshaper']);
    expect(
      aboutDrawing(
        settings,
        engine.available(settings),
        engine.lorasFor(settings),
      ),
      contains('- Ink: Trigger: inkstyle. For SD 1.5 models.'),
    );
    final drawn = <File>[];
    engine.onDrawn = (job, file) async => drawn.add(file);
    while (engine.busy || engine.waiting > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(drawn.single.readAsBytesSync(), png);
    final nodes = ((posted.single['batch'] as Map)['graph'] as Map)['nodes'];
    expect(((nodes as Map)['model'] as Map)['type'], 'main_model_loader');
    expect((nodes['lora0'] as Map)['weight'], 0.5);
    expect((nodes['noise'] as Map)['width'], 512);
  });
}
