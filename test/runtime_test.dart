import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/memory/memory_tools.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/llm_client.dart';
import 'package:companion/services/runtime/download.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/runtime/runtime_installer.dart';
import 'package:companion/services/sight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('pickAssets', () {
    const tag = RuntimeInstaller.pinnedTag;
    final names = [
      'llama-$tag-bin-ubuntu-x64.tar.gz',
      'llama-$tag-bin-ubuntu-vulkan-x64.tar.gz',
      'llama-$tag-bin-macos-arm64.tar.gz',
      'llama-$tag-bin-macos-x64.tar.gz',
      'llama-$tag-bin-win-cpu-x64.zip',
      'llama-$tag-bin-win-vulkan-x64.zip',
      'llama-$tag-bin-win-cuda-12.4-x64.zip',
      'cudart-llama-bin-win-cuda-12.4-x64.zip',
      'llama-$tag-bin-win-cuda-13.1-x64.zip',
      'cudart-llama-bin-win-cuda-13.1-x64.zip',
    ];

    test('Linux prefers the Vulkan build', () {
      expect(RuntimeInstaller.pickAssets(names, os: 'linux', arm: false), [
        'llama-$tag-bin-ubuntu-vulkan-x64.tar.gz',
      ]);
      expect(
        RuntimeInstaller.pickAssets(
          names.where((n) => !n.contains('vulkan')),
          os: 'linux',
          arm: false,
        ),
        ['llama-$tag-bin-ubuntu-x64.tar.gz'],
      );
    });

    test('macOS picks by architecture', () {
      expect(RuntimeInstaller.pickAssets(names, os: 'macos', arm: true), [
        'llama-$tag-bin-macos-arm64.tar.gz',
      ]);
    });

    test('Windows layers Vulkan over the CPU build', () {
      expect(RuntimeInstaller.pickAssets(names, os: 'windows', arm: false), [
        'llama-$tag-bin-win-cpu-x64.zip',
        'llama-$tag-bin-win-vulkan-x64.zip',
      ]);
    });

    test('Windows with an NVIDIA card gets CUDA 12 and its runtime', () {
      expect(
        RuntimeInstaller.pickAssets(
          names,
          os: 'windows',
          arm: false,
          cuda: true,
        ),
        [
          'llama-$tag-bin-win-cpu-x64.zip',
          'llama-$tag-bin-win-cuda-12.4-x64.zip',
          'cudart-llama-bin-win-cuda-12.4-x64.zip',
        ],
      );
    });

    test('CUDA without its runtime archive falls back to Vulkan', () {
      expect(
        RuntimeInstaller.pickAssets(
          names.where((n) => !n.startsWith('cudart')),
          os: 'windows',
          arm: false,
          cuda: true,
        ),
        ['llama-$tag-bin-win-cpu-x64.zip', 'llama-$tag-bin-win-vulkan-x64.zip'],
      );
    });

    test('driver version is read from nvidia-smi output', () {
      expect(RuntimeInstaller.parseDriverMajor('551.61\n'), 551);
      expect(RuntimeInstaller.parseDriverMajor(''), isNull);
    });
  });

  test('downloadFile resumes a partial download', () async {
    final payload = List<int>.generate(100000, (i) => i % 251);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ranges = <String?>[];
    server.listen((req) async {
      final range = req.headers.value('range');
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        req.response.statusCode = 206;
      }
      req.response.contentLength = payload.length - start;
      req.response.add(payload.sublist(start));
      await req.response.close();
    });
    final tmp = await Directory.systemTemp.createTemp('dl_test');
    addTearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    final target = File(p.join(tmp.path, 'model.gguf'));
    await File('${target.path}.part').writeAsBytes(payload.sublist(0, 40000));
    double? last;
    await downloadFile(
      http.Client(),
      Uri.parse('http://127.0.0.1:${server.port}/m'),
      target,
      onProgress: (got, total) => last = got / total!,
    );
    expect(ranges, ['bytes=40000-']);
    expect(await target.readAsBytes(), payload);
    expect(last, 1.0);
    expect(await File('${target.path}.part').exists(), isFalse);
  });

  test(
    'downloadFile fetches big files over several connections and resumes',
    () async {
      final payload = List<int>.generate(
        34 * 1024 * 1024,
        (i) => (i * 7) % 253,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ranges = <String>[];
      server.listen((req) async {
        final m = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(req.headers.value('range') ?? '');
        if (m == null) {
          req.response.contentLength = payload.length;
          req.response.add(payload);
        } else {
          ranges.add(m.group(0)!);
          final start = int.parse(m.group(1)!);
          final end = m.group(2)!.isEmpty
              ? payload.length - 1
              : int.parse(m.group(2)!);
          req.response.statusCode = 206;
          req.response.headers.set(
            'content-range',
            'bytes $start-$end/${payload.length}',
          );
          req.response.contentLength = end - start + 1;
          req.response.add(payload.sublist(start, end + 1));
        }
        await req.response.close();
      });
      final tmp = await Directory.systemTemp.createTemp('dl_par_test');
      addTearDown(() async {
        await server.close(force: true);
        await tmp.delete(recursive: true);
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/m');
      final target = File(p.join(tmp.path, 'big.gguf'));

      // Cancel part way, then finish: the second run must not start over.
      var calls = 0;
      await expectLater(
        downloadFile(
          http.Client(),
          url,
          target,
          isCancelled: () => ++calls > 6,
        ),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(await target.exists(), isFalse);
      ranges.clear();
      var last = 0;
      await downloadFile(
        http.Client(),
        url,
        target,
        onProgress: (got, _) => last = got,
      );
      expect(await target.length(), payload.length);
      expect(await target.readAsBytes(), payload);
      expect(last, payload.length);
      expect(ranges.length, greaterThan(1));
      var asked = 0;
      for (final r in ranges) {
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(r)!;
        asked += int.parse(m.group(2)!) - int.parse(m.group(1)!) + 1;
      }
      expect(asked, lessThanOrEqualTo(payload.length));
      expect(await File('${target.path}.part').exists(), isFalse);
      expect(await File('${target.path}.part.segs').exists(), isFalse);
    },
  );

  // Real llama.cpp end to end. Runs when LLAMA_SERVER_DIR (a folder with a
  // built llama-server) and TEST_GGUF (any small model) are set.
  final binDir = Platform.environment['LLAMA_SERVER_DIR'];
  final gguf = Platform.environment['TEST_GGUF'];
  test(
    'runtime starts llama-server and streams a reply',
    () async {
      final support = await Directory.systemTemp.createTemp('runtime_test');
      // Pretend the pinned runtime was already downloaded.
      final install = Directory(
        p.join(support.path, 'runtime', RuntimeInstaller.pinnedTag),
      );
      await install.create(recursive: true);
      for (final f in Directory(binDir!).listSync()) {
        await Link(p.join(install.path, p.basename(f.path))).create(f.path);
      }
      final runtime = RuntimeController(support);
      addTearDown(() async {
        await runtime.stop();
        await support.delete(recursive: true);
      });

      final settings = AppSettings(
        modelPath: gguf,
        contextSize: 2048,
        useGpu: false,
      );
      final target = await runtime.ensureReady(settings);
      expect(runtime.state, RuntimeState.ready);
      // A second call reuses the running server.
      expect((await runtime.ensureReady(settings)).baseUrl, target.baseUrl);

      final client = LlmClient(
        baseUrl: target.baseUrl,
        model: target.model,
        apiKey: target.apiKey,
        maxTokens: 64,
        progress: true,
        firstWait: const Duration(minutes: 1),
        stallWait: const Duration(seconds: 30),
      );
      final text = StringBuffer();
      var progress = 0;
      await for (final e in client.chat([
        {'role': 'user', 'content': 'Hello'},
      ])) {
        if (e is TextDelta) text.write(e.text);
        if (e is PromptProgress) progress++;
      }
      expect(text.toString(), isNotEmpty);
      // llama-server reports reading the prompt, and how the reply ended.
      expect(progress, greaterThan(0));
      expect(client.finishReason, isNotNull);

      // Chat always offers the memory tools; the server must accept them.
      final withTools = await client.chat([
        {'role': 'user', 'content': 'Remember I like tea'},
      ], tools: MemoryTools.definitions).toList();
      expect(withTools, isNotEmpty);

      // The whole chat path on the built-in runtime: prompt, tools, history.
      final db = await openAppDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final services = AppServices(
        settings: SettingsStore(
          File(p.join(support.path, 'settings.json')),
          settings.copyWith(companionFolder: p.join(support.path, 'home')),
        ),
        db: db,
        // In memory: nothing to encrypt.
        dbKey: DatabaseKey(Directory.systemTemp),
        runtime: runtime,
      );
      final chat = ChatController(services);
      await chat.send('Hi there');
      expect(chat.error, isNull);
      expect(chat.messages.map((m) => m.role), ['user', 'assistant']);

      await runtime.stop();
      expect(runtime.state, RuntimeState.idle);
    },
    skip: binDir == null || gguf == null
        ? 'set LLAMA_SERVER_DIR and TEST_GGUF to run'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // A stand-in llama-server that crashes on its first reply, as a real one
  // can when the graphics card runs out of memory, and works once started
  // again.
  test(
    'a built-in model that crashes mid-reply is started again',
    () async {
      final support = await Directory.systemTemp.createTemp('crash_test');
      addTearDown(() => support.delete(recursive: true));
      final install = Directory(
        p.join(support.path, 'runtime', RuntimeInstaller.pinnedTag),
      );
      await install.create(recursive: true);
      final crashed = File(p.join(support.path, 'crashed'));
      final exe = File(p.join(install.path, RuntimeInstaller.exeName));
      await exe.writeAsString(_fakeServer(crashed.path));
      await Process.run('chmod', ['+x', exe.path]);
      final model = File(p.join(support.path, 'model.gguf'));
      await model.writeAsString('not really a model');

      final runtime = RuntimeController(support);
      addTearDown(runtime.stopAll);
      final db = await openAppDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final services = AppServices(
        settings: SettingsStore(
          File(p.join(support.path, 'settings.json')),
          AppSettings(
            companionName: 'Aria',
            companionFolder: p.join(support.path, 'home'),
            modelPath: model.path,
            contextSize: 2048,
            useGpu: false,
          ),
        ),
        db: db,
        dbKey: DatabaseKey(Directory.systemTemp),
        runtime: runtime,
      );
      final chat = ChatController(services);
      await chat.send('Hi there');
      expect(await crashed.exists(), isTrue);
      expect(chat.error, isNull);
      expect(chat.messages.last.content, 'Hello again.');
      expect(chat.toolNote, contains('started again'));
      final logged = await services.log.entries();
      expect(
        logged.map((e) => e.message),
        contains(contains('GGML_ASSERT(oops) failed')),
      );
    },
    skip: Platform.isWindows ? 'the stand-in server is a script' : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // Real Eyes end to end. Runs when LLAMA_SERVER_DIR is set and
  // TEST_EYES_DIR holds the Eyes model and vision files.
  final eyesDir = Platform.environment['TEST_EYES_DIR'];
  test(
    'Eyes describes a picture, and a model that sees gets it in the chat',
    () async {
      final support = await Directory.systemTemp.createTemp('eyes_test');
      final install = Directory(
        p.join(support.path, 'runtime', RuntimeInstaller.pinnedTag),
      );
      await install.create(recursive: true);
      for (final f in Directory(binDir!).listSync()) {
        await Link(p.join(install.path, p.basename(f.path))).create(f.path);
      }
      final runtime = RuntimeController(support);
      addTearDown(() async {
        await runtime.stopAll();
        await support.delete(recursive: true);
      });

      // A red disc on white, with a word in it.
      final picture = img.Image(width: 400, height: 300)
        ..clear(img.ColorRgb8(255, 255, 255));
      img.fillCircle(
        picture,
        x: 200,
        y: 150,
        radius: 120,
        color: img.ColorRgb8(220, 20, 20),
      );
      img.drawString(
        picture,
        'TEA',
        font: img.arial48,
        x: 160,
        y: 125,
        color: img.ColorRgb8(255, 255, 255),
      );
      final file = File(p.join(support.path, 'disc.png'))
        ..writeAsBytesSync(img.encodePng(picture));

      final settings = AppSettings(
        modelsFolder: eyesDir,
        contextSize: 4096,
        useGpu: false,
      );
      expect(ModelCatalog.eyesInstalled(settings), isTrue);
      final description = await runtime.describePicture(
        settings,
        await Sight.dataUrl(file),
        said: 'What do you think?',
      );
      expect(description.toLowerCase(), contains('red'));

      // The same model, attached with its vision file, sees by itself.
      final files = ModelCatalog.eyesFiles(settings)!;
      final db = await openAppDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final services = AppServices(
        settings: SettingsStore(
          File(p.join(support.path, 'settings.json')),
          settings.copyWith(
            companionName: 'Aria',
            companionFolder: p.join(support.path, 'home'),
            modelPath: files.model,
            mmprojPath: files.mmproj,
          ),
        ),
        db: db,
        dbKey: DatabaseKey(Directory.systemTemp),
        runtime: runtime,
      );
      expect(Sight.modeFor(services.settings.value), SightMode.native);
      final chat = ChatController(services);
      await chat.send(
        'What colour is the circle in this picture?',
        images: [file.path],
      );
      expect(chat.error, isNull);
      expect(chat.messages.last.content.toLowerCase(), contains('red'));
      // ignore: avoid_print
      print('Eyes: $description\nChat: ${chat.messages.last.content}');

      // Without its vision file the model is blind, and Eyes looks for it.
      await services.settings.update(
        services.settings.value.copyWith(clearMmproj: true),
      );
      expect(Sight.modeFor(services.settings.value), SightMode.eyes);
      await chat.send('And now, what is written on it?', images: [file.path]);
      expect(chat.error, isNull);
      expect(chat.messages.last.content.toLowerCase(), contains('tea'));
      final rel = RegExp(
        r'images/[^\]]+',
      ).firstMatch(chat.messages[chat.messages.length - 2].content)![0]!;
      expect(await services.pictureNotes.get(rel), isNotNull);
      // ignore: avoid_print
      print('Through Eyes: ${chat.messages.last.content}');
    },
    skip: binDir == null || eyesDir == null
        ? 'set LLAMA_SERVER_DIR and TEST_EYES_DIR to run'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test('every catalog file is pinned to a commit and a checksum', () {
    for (final m in [...ModelCatalog.models, ModelCatalog.eyes]) {
      expect(m.revision, matches(RegExp(r'^[0-9a-f]{40}$')), reason: m.id);
      for (final f in m.allFiles) {
        expect(m.sha256[f], matches(RegExp(r'^[0-9a-f]{64}$')), reason: f);
        expect(m.urlFor(f).path, contains('/resolve/${m.revision}/'));
      }
    }
  });
}

/// A Python stand-in for llama-server: answers /health, and the first chat
/// request writes a word, says what failed and exits, the way a crash
/// looks. Later starts reply in full.
String _fakeServer(String crashedMarker) =>
    r"""#!/usr/bin/env python3
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[sys.argv.index('--port') + 1])
marker = '""" +
    crashedMarker +
    r"""'

def chunk(text):
    return 'data: ' + json.dumps(
        {'choices': [{'delta': {'content': text}, 'finish_reason': None}]}
    ) + '\n\n'

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', '100000')
        self.end_headers()
        if not os.path.exists(marker):
            open(marker, 'w').close()
            self.wfile.write(chunk('Hel').encode())
            self.wfile.flush()
            sys.stderr.write('/src/ggml.c:1: GGML_ASSERT(oops) failed\n')
            sys.stderr.flush()
            os._exit(3)
        self.wfile.write((chunk('Hello again.') + 'data: [DONE]\n\n').encode())
        self.wfile.flush()
        self.close_connection = True

HTTPServer(('127.0.0.1', port), H).serve_forever()
""";
