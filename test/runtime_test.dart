import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/memory/memory_tools.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/llm_client.dart';
import 'package:companion/services/runtime/download.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/runtime/runtime_installer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

  test('every catalog file is pinned to a commit and a checksum', () {
    for (final m in ModelCatalog.models) {
      expect(m.revision, matches(RegExp(r'^[0-9a-f]{40}$')), reason: m.id);
      for (final f in m.allFiles) {
        expect(m.sha256[f], matches(RegExp(r'^[0-9a-f]{64}$')), reason: f);
        expect(m.urlFor(f).path, contains('/resolve/${m.revision}/'));
      }
    }
  });
}
