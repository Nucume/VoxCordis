import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/services/runtime/llama_server.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/runtime/runtime_installer.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// A stand-in llama-server that prints a model-load error and exits, the
/// way a real one does with a model it can't read. [who] tells the builds
/// apart in the error.
String _failingServer(String who) =>
    '#!/bin/sh\n'
    'echo "$who: llama_model_load: error loading model: '
    'unknown model architecture" >&2\n'
    'exit 1\n';

/// A stand-in llama-server that hangs while loading: it never answers.
const _hangingServer = '#!/bin/sh\nexec sleep 60\n';

/// A Python stand-in for llama-server that answers /health with the model
/// it was started with. A model whose name has "slow" in it takes two
/// seconds to load.
const _workingServer = r"""#!/usr/bin/env python3
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[sys.argv.index('--port') + 1])
model = sys.argv[sys.argv.index('-m') + 1]
if 'slow' in model:
    time.sleep(2)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({'status': 'ok', 'model': model}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(('127.0.0.1', port), H).serve_forever()
""";

Future<String> _put(Directory dir, String script) async {
  await dir.create(recursive: true);
  final exe = File(p.join(dir.path, RuntimeInstaller.exeName));
  await exe.writeAsString(script);
  await Process.run('chmod', ['+x', exe.path]);
  return exe.path;
}

/// GitHub can't be reached.
final _offline = MockClient((_) async => http.Response('', 503));

void main() {
  late Directory support;
  late File model;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('cuda_fallback');
    model = File(p.join(support.path, 'model.gguf'));
    await model.writeAsString('not really a model');
  });
  tearDown(() => support.delete(recursive: true));

  RuntimeController runtimeWithCuda(
    List<String> logs, {
    Duration? loadTimeout,
  }) {
    final runtime = RuntimeController(
      support,
      client: _offline,
      nvidiaDriver: () async => 550,
      loadTimeout: loadTimeout,
    );
    runtime.installer.note = logs.add;
    addTearDown(runtime.stopAll);
    return runtime;
  }

  File marker() => File(
    p.join(support.path, 'runtime', '${RuntimeInstaller.pinnedTag}.no-cuda'),
  );

  group('CUDA fallback', () {
    test(
      'a model that fails on both builds keeps CUDA and shows its error',
      () async {
        final logs = <String>[];
        final runtime = runtimeWithCuda(logs);
        final cuda = await _put(
          runtime.installer.cudaInstallDir,
          _failingServer('CUDA build'),
        );
        await _put(
          runtime.installer.installDir,
          _failingServer('Vulkan build'),
        );

        await expectLater(
          runtime.ensureReady(
            AppSettings(modelPath: model.path, contextSize: 2048),
          ),
          throwsA(predicate((e) => '$e'.contains('CUDA build'))),
        );
        expect(marker().existsSync(), isFalse);
        expect(await runtime.installer.find(), cuda);
        expect(logs, contains(contains('so CUDA is kept')));
        expect(logs, isNot(contains(contains('so Vulkan is used'))));
      },
    );

    test('offline, a model that fails on CUDA keeps CUDA', () async {
      final runtime = runtimeWithCuda([]);
      final cuda = await _put(
        runtime.installer.cudaInstallDir,
        _failingServer('CUDA build'),
      );

      await expectLater(
        runtime.ensureReady(
          AppSettings(modelPath: model.path, contextSize: 2048),
        ),
        throwsA(predicate((e) => '$e'.contains('CUDA build'))),
      );
      expect(marker().existsSync(), isFalse);
      expect(await runtime.installer.find(), cuda);
    });

    test('when only CUDA fails, Vulkan is used and remembered', () async {
      final logs = <String>[];
      final runtime = runtimeWithCuda(logs);
      await _put(runtime.installer.cudaInstallDir, _failingServer('CUDA'));
      final vulkan = await _put(runtime.installer.installDir, _workingServer);

      await runtime.ensureReady(
        AppSettings(modelPath: model.path, contextSize: 2048),
      );
      expect(runtime.state, RuntimeState.ready);
      expect(marker().existsSync(), isTrue);
      expect(await runtime.installer.find(), vulkan);
      expect(logs, contains(contains('so Vulkan is used')));
    });

    test(
      'a CUDA build that hangs while loading is off for the rest of the run',
      () async {
        final logs = <String>[];
        final runtime = runtimeWithCuda(
          logs,
          loadTimeout: const Duration(seconds: 5),
        );
        final cuda = await _put(
          runtime.installer.cudaInstallDir,
          _hangingServer,
        );
        final vulkan = await _put(runtime.installer.installDir, _workingServer);
        final settings = AppSettings(modelPath: model.path, contextSize: 2048);

        // Not tried on Vulkan at once, so a model too big to load is not
        // loaded twice.
        await expectLater(
          runtime.ensureReady(settings),
          throwsA(
            isA<LlamaServerException>().having(
              (e) => e.timedOut,
              'timedOut',
              isTrue,
            ),
          ),
        );
        expect(marker().existsSync(), isFalse);
        expect(await runtime.installer.find(), vulkan);
        expect(logs, contains(contains('Vulkan is used for the rest')));

        // The next try in this run uses Vulkan.
        await runtime.ensureReady(settings);
        expect(runtime.state, RuntimeState.ready);

        // At the next start CUDA gets another go.
        final next = RuntimeInstaller(support, nvidiaDriver: () async => 550);
        expect(await next.find(), cuda);
      },
    );

    test('Recall falls back from a CUDA build that will not start', () async {
      final runtime = runtimeWithCuda([]);
      await _put(runtime.installer.cudaInstallDir, _failingServer('CUDA'));
      await _put(runtime.installer.installDir, _workingServer);
      final models = Directory(p.join(support.path, 'models'))..createSync();
      ModelCatalog.fileFor(
        models,
        ModelCatalog.recall,
      ).writeAsStringSync('not really a model');

      final server = await runtime.ensureRecall(
        AppSettings(modelsFolder: models.path),
      );
      expect(server.port, greaterThan(0));
      expect(marker().existsSync(), isTrue);
    });
  }, skip: Platform.isLinux ? false : 'the CUDA fallback is Linux only here');

  test('once CUDA failed, it stays off for the rest of the run', () async {
    final installer = RuntimeInstaller(support, nvidiaDriver: () async => 550);
    await _put(installer.cudaInstallDir, '');
    final vulkan = await _put(installer.installDir, '');

    await installer.giveUpOnCuda('it crashed');
    // A day later the marker has run out, but the app is still open.
    await marker().setLastModified(
      DateTime.now().subtract(const Duration(hours: 25)),
    );
    expect(await installer.find(), vulkan);
    expect(await installer.ensureInstalled(), vulkan);

    // At the next start CUDA gets another go.
    final next = RuntimeInstaller(support, nvidiaDriver: () async => 550);
    expect(installer.isCuda((await next.find())!), isTrue);
  }, skip: Platform.isLinux ? false : 'the CUDA fallback is Linux only here');

  /// An installer whose download of the Linux Vulkan build takes a moment.
  /// [onDownload] is called for each download started.
  RuntimeInstaller slowInstaller(void Function() onDownload) {
    final tar = TarEncoder().encodeBytes(
      Archive()..addFile(
        ArchiveFile.bytes(
          'build/bin/${RuntimeInstaller.exeName}',
          utf8.encode('#!/bin/sh\n'),
        ),
      ),
    );
    final asset = GZipEncoder().encodeBytes(tar);
    const tag = RuntimeInstaller.pinnedTag;
    const name = 'llama-$tag-bin-ubuntu-vulkan-x64.tar.gz';
    const url = 'https://example.test/$name';
    final client = MockClient((req) async {
      if (req.url.host == 'api.github.com') {
        return http.Response(
          jsonEncode({
            'assets': [
              {
                'name': name,
                'browser_download_url': url,
                'digest': 'sha256:${sha256.convert(asset)}',
              },
            ],
          }),
          200,
        );
      }
      if (req.headers['Range'] == null) onDownload();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return http.Response.bytes(asset, 200);
    });
    return RuntimeInstaller(
      support,
      client: client,
      nvidiaDriver: () async => null,
    );
  }

  group('installs at the same time', () {
    test('share one download', () async {
      var downloads = 0;
      final installer = slowInstaller(() => downloads++);

      final paths = await Future.wait([
        installer.ensureInstalled(),
        installer.ensureInstalled(),
      ]);
      expect(downloads, 1);
      expect(paths[0], paths[1]);
      expect(File(paths[0]).existsSync(), isTrue);
    });

    test('all show the progress', () async {
      final installer = slowInstaller(() {});
      var first = 0;
      var second = 0;

      await Future.wait([
        installer.ensureInstalled(onProgress: (_, _) => first++),
        installer.ensureInstalled(onProgress: (_, _) => second++),
      ]);
      expect(first, greaterThan(0));
      expect(second, greaterThan(0));
    });
  }, skip: Platform.isLinux ? false : 'the asset is the Linux one');

  test(
    'a model asked for while another loads gets its own server',
    () async {
      final runtime = RuntimeController(
        support,
        client: _offline,
        nvidiaDriver: () async => null,
      );
      addTearDown(runtime.stopAll);
      await _put(runtime.installer.installDir, _workingServer);
      final slow = File(p.join(support.path, 'slow.gguf'))
        ..writeAsStringSync('a');

      final first = runtime.ensureReady(
        AppSettings(modelPath: slow.path, contextSize: 2048),
      );
      final second = runtime.ensureReady(
        AppSettings(modelPath: model.path, contextSize: 2048),
      );
      await first;
      final target = await second;
      final health = await http.get(
        Uri.parse(target.baseUrl).replace(path: '/health'),
      );
      expect(jsonDecode(health.body)['model'], model.path);
      expect(runtime.state, RuntimeState.ready);
    },
    skip: Platform.isWindows ? 'the stand-in server is a script' : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
