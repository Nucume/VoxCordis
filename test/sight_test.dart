import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/desk/shared_files.dart';
import 'package:companion/data/picture_notes.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/attachments_prompt.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/llm_client.dart';
import 'package:companion/services/runtime/gpu_info.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/sight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('sight'));
  tearDown(() => tmp.delete(recursive: true));

  group('shared files', () {
    test('are sorted into pictures, text and the rest by content', () async {
      Future<SharedKind?> kind(String name, List<int> bytes) async {
        final f = File(p.join(tmp.path, name));
        await f.writeAsBytes(bytes);
        return SharedFiles.kindOf(f.path);
      }

      expect(await kind('a.png', _png(2, 2)), SharedKind.picture);
      // A picture with the wrong ending is still a picture.
      expect(await kind('photo.txt', _png(2, 2)), SharedKind.picture);
      expect(
        await kind('notes.md', utf8.encode('# Hi\nthere')),
        SharedKind.text,
      );
      expect(await kind('README', utf8.encode('plain')), SharedKind.text);
      expect(await kind('doc.pdf', utf8.encode('%PDF-1.7\n\x00\x01')), isNull);
      expect(await kind('app.exe', [0x4D, 0x5A, 0, 0, 3]), isNull);
      expect(await kind('gone.txt', []), SharedKind.text);
      expect(await SharedFiles.kindOf(p.join(tmp.path, 'nope')), isNull);
    });

    test('a character cut at the end of the sample is still text', () {
      final bytes = utf8.encode('héllo ✨');
      expect(SharedFiles.looksLikeText(bytes), isTrue);
      expect(
        SharedFiles.looksLikeText(bytes.sublist(0, bytes.length - 1)),
        isTrue,
      );
      expect(
        SharedFiles.looksLikeText([0xFF, 0xFE, 0x41, 0x42, 0x43]),
        isFalse,
      );
    });

    test('markers name files and leave the text', () {
      const message =
          'Look at these\n\n[image: images/a.png]\n[file: files/b.md]';
      expect(SharedFiles.inText(message), ['files/b.md']);
      expect(SharedFiles.withoutMarkers(message), 'Look at these');
    });

    test('share copies into files/, and nothing outside is read', () async {
      final src = File(p.join(tmp.path, 'notes.txt'))..writeAsStringSync('x');
      final folder = p.join(tmp.path, 'Aria');
      final rel = await SharedFiles.share(folder, src.path, DateTime(2026));
      expect(rel, startsWith('files/2026-01-01_000000-notes'));
      expect(File(p.join(folder, rel)).readAsStringSync(), 'x');
      expect(SharedFiles.fileIn(folder, '../secret.txt'), isNull);
    });
  });

  group('sight', () {
    test('pictures leave the computer only for a remote server', () {
      bool leaves(String endpoint) => Sight.picturesLeave(
        AppSettings(llmMode: LlmMode.external, llmEndpoint: endpoint),
      );
      expect(leaves('https://openrouter.ai/api/v1'), isTrue);
      expect(leaves('https://api.anthropic.com/v1'), isTrue);
      expect(leaves('https://my-server.example.com/v1'), isTrue);
      expect(leaves('http://localhost:11434/v1'), isFalse);
      expect(leaves('http://127.0.0.1:1234/v1'), isFalse);
      expect(leaves('http://192.168.1.20:1234/v1'), isFalse);
      expect(leaves('http://10.0.0.5:1234/v1'), isFalse);
      expect(leaves('http://172.20.0.5:1234/v1'), isFalse);
      expect(leaves('http://172.40.0.5:1234/v1'), isTrue);
      expect(Sight.picturesLeave(const AppSettings()), isFalse);
    });

    test('a local model sees with its vision file, else Eyes, else not', () {
      final qwenVl = ModelCatalog.models.firstWhere(
        (m) => m.id == 'qwen3-vl-8b',
      );
      final model = File(p.join(tmp.path, qwenVl.file))..createSync();
      final s = AppSettings(modelPath: model.path, modelsFolder: tmp.path);
      expect(Sight.modeFor(s), SightMode.none);
      File(p.join(tmp.path, qwenVl.mmproj!)).createSync();
      expect(ModelCatalog.mmprojFor(s), p.join(tmp.path, qwenVl.mmproj!));
      expect(Sight.modeFor(s), SightMode.native);

      // An attached model sees only with the vision file attached to it.
      final own = File(p.join(tmp.path, 'mine.gguf'))..createSync();
      final attached = s.copyWith(modelPath: own.path);
      expect(Sight.modeFor(attached), SightMode.none);
      for (final f in ModelCatalog.eyes.allFiles) {
        File(p.join(tmp.path, f)).createSync();
      }
      expect(Sight.modeFor(attached), SightMode.eyes);
      final mmproj = File(p.join(tmp.path, 'mmproj-mine.gguf'))..createSync();
      expect(
        Sight.modeFor(attached.copyWith(mmprojPath: mmproj.path)),
        SightMode.native,
      );
    });

    test('a server model sees until it turns a picture down', () {
      const s = AppSettings(
        llmMode: LlmMode.external,
        llmEndpoint: 'https://openrouter.ai/api/v1',
        llmModel: 'some/model',
      );
      expect(Sight.modeFor(s), SightMode.native);
      expect(Sight.modeFor(s, blind: {Sight.serverKey(s)}), SightMode.none);
    });

    test('small pictures go as they are, big ones scaled to JPEG', () {
      final small = _png(40, 30);
      expect(
        Sight.dataUrlOf(small),
        'data:image/png;base64,${base64Encode(small)}',
      );
      final big = Sight.dataUrlOf(_png(3000, 1000));
      expect(big, startsWith('data:image/jpeg;base64,'));
      final back = img.decodeJpg(base64Decode(big.split(',').last))!;
      expect([back.width, back.height], [1280, 427]);
      expect(() => Sight.dataUrlOf(Uint8List(8)), throwsFormatException);
    });

    test('pasted bitmaps become PNG', () {
      final bmp = img.encodeBmp(img.Image(width: 3, height: 3));
      final png = Sight.normalizePasted(bmp)!;
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(Sight.normalizePasted(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('catalog', () {
    test(
      'vision files download before the model and are never models',
      () async {
        final eyes = ModelCatalog.eyes;
        expect(eyes.allFiles, [eyes.mmproj, eyes.file]);
        for (final name in [
          'model.gguf',
          'mmproj-model-f16.gguf',
          p.basename(eyes.file),
        ]) {
          File(p.join(tmp.path, name)).createSync();
        }
        final found = await ModelCatalog.downloaded(tmp);
        expect(found.map((f) => p.basename(f.path)), ['model.gguf']);
      },
    );

    test('models that see are never the recommendation', () {
      for (final gb in [8.0, 9.0, 12.0, 24.0]) {
        expect(
          ModelCatalog.recommendFor(GpuInfo(memoryGb: gb))!.canSee,
          isFalse,
        );
      }
    });

    test('an attached model brings the one vision file beside it', () {
      final model = File(p.join(tmp.path, 'gemma.gguf'))..createSync();
      expect(ModelCatalog.mmprojBeside(model.path), isNull);
      File(p.join(tmp.path, 'mmproj-gemma.gguf')).createSync();
      expect(
        ModelCatalog.mmprojBeside(model.path),
        p.join(tmp.path, 'mmproj-gemma.gguf'),
      );
      File(p.join(tmp.path, 'mmproj-other.gguf')).createSync();
      expect(ModelCatalog.mmprojBeside(model.path), isNull);
    });
  });

  group('prompt attachments', () {
    late Database db;
    late PictureNotes notes;
    late String folder;
    setUp(() async {
      db = await openAppDatabase(inMemoryDatabasePath);
      notes = PictureNotes(db);
      folder = p.join(tmp.path, 'Aria');
    });
    tearDown(() => db.close());

    List<Map<String, Object?>> turns(List<String> users) => [
      for (final u in users) ...[
        {'role': 'user', 'content': u},
        {'role': 'assistant', 'content': 'ok'},
      ],
    ];

    test('only the latest pictures are sent; older ones are named', () async {
      await notes.put('images/1.png', 'A red kite', seenBy: 'Eyes');
      final looked = <String>[];
      final a = PromptAttachments(
        folder: folder,
        mode: SightMode.native,
        notes: notes,
        fileChars: 1000,
        pictureUrl: (rel) async => 'data:$rel',
        look: (rel, said) async {
          looked.add(rel);
          return null;
        },
      );
      final out = await a.expand(
        turns([
          'first\n[image: images/1.png]',
          'second\n[image: images/2.png]',
          'no pictures',
          'third\n[image: images/3.png]\n[image: images/4.png]',
        ]),
      );
      expect(
        out[0]['content'],
        'first\n[image: images/1.png, which you saw earlier: A red kite]',
      );
      final second = out[2]['content'] as List;
      expect((second.first as Map)['text'], 'second\n[image: images/2.png]');
      expect(
        ((second.last as Map)['image_url'] as Map)['url'],
        'data:images/2.png',
      );
      expect(out[4]['content'], 'no pictures');
      expect(out[6]['content'], hasLength(3)); // text and two pictures
      expect(out[1]['content'], 'ok');
      expect(a.sentPictures, isTrue);
      expect(looked, isEmpty);
    });

    test('Eyes looks once at new pictures and its words are kept', () async {
      var looks = 0;
      Future<String?> look(String rel, String said) async {
        looks++;
        if (rel.contains('broken')) return null;
        expect(said, 'my cat');
        await notes.put(rel, 'A grey cat on a sofa', seenBy: 'Eyes');
        return 'A grey cat on a sofa';
      }

      final a = PromptAttachments(
        folder: folder,
        mode: SightMode.eyes,
        notes: notes,
        fileChars: 1000,
        pictureUrl: (rel) async => fail('Eyes mode sends no pictures'),
        look: look,
      );
      var out = await a.expand(turns(['my cat\n[image: images/cat.png]']));
      expect(
        out[0]['content'],
        'my cat\n[image: images/cat.png. You see: A grey cat on a sofa]',
      );
      out = await a.expand(turns(['my cat\n[image: images/cat.png]']));
      expect(looks, 1);
      out = await a.expand(turns(['my cat\n[image: images/broken.png]']));
      expect(out[0]['content'], contains("You couldn't look at it"));
      expect(a.unseen, ['images/broken.png']);
      expect(a.sentPictures, isFalse);
    });

    test('without sight the companion is told it can\'t see', () async {
      final a = PromptAttachments(
        folder: folder,
        mode: SightMode.none,
        notes: notes,
        fileChars: 1000,
        pictureUrl: (rel) async => fail('nothing is sent'),
      );
      final out = await a.expand(turns(['[image: images/x.png]']));
      expect(
        out[0]['content'],
        "[image: images/x.png. You can't see pictures.]",
      );
    });

    test('the latest files carry their text, cut to the budget', () async {
      final dir = Directory(p.join(folder, 'files'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'old.md')).writeAsStringSync('old text');
      File(p.join(dir.path, 'code.md')).writeAsStringSync('a ``` fence');
      File(p.join(dir.path, 'long.txt')).writeAsStringSync('x' * 50);
      final a = PromptAttachments(
        folder: folder,
        mode: SightMode.none,
        notes: notes,
        fileChars: 40,
        pictureUrl: (rel) async => null,
        recent: 1,
      );
      final out = await a.expand(
        turns([
          '[file: files/old.md]',
          'see\n[file: files/code.md]\n[file: files/long.txt]',
        ]),
      );
      expect(out[0]['content'], contains('shared earlier; read_file'));
      final latest = out[2]['content'] as String;
      expect(
        latest,
        contains('[file: files/code.md]\n````\na ``` fence\n````'),
      );
      // Two files share the 40 characters.
      expect(latest, contains('${'x' * 20}\n```'));
      expect(latest, contains('Only the start of the file'));
    });
  });

  test('a server model that turns pictures down gets them as names', () async {
    final requests = <Map>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map;
      requests.add(body);
      if (jsonEncode(body).contains('image_url')) {
        req.response.statusCode = 400;
        req.response.write(
          '{"error":{"message":"No endpoints found that support image input"}}',
        );
      } else {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'Tell me about it!'},
              },
            ],
          })}\n\n',
        );
        req.response.write('data: [DONE]\n\n');
      }
      await req.response.close();
    });
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File(p.join(tmp.path, 'settings.json')),
        AppSettings(
          companionName: 'Aria',
          companionFolder: p.join(tmp.path, 'Aria'),
          llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
          llmMode: LlmMode.external,
          llmModel: 'text-only',
          modelsFolder: p.join(tmp.path, 'models'),
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

    final picture = File(p.join(tmp.path, 'cat.png'))
      ..writeAsBytesSync(_png(8, 8));
    final chat = ChatController(services);
    await chat.send('look', images: [picture.path]);

    expect(chat.error, isNull);
    expect(chat.messages.last.content, 'Tell me about it!');
    expect(chat.toolNote, "text-only can't see pictures");
    expect(requests, hasLength(2));
    final retried = (requests.last['messages'] as List).last as Map;
    expect(retried['content'], contains("You can't see pictures."));
    expect(
      ((requests.last['messages'] as List).first as Map)['content'],
      contains('Settings → Brain'),
    );

    // The next picture goes as a name straight away.
    await chat.send('another', images: [picture.path]);
    expect(requests, hasLength(3));
    expect(
      ChatController.refusedPictures(LlmException('HTTP 401: bad key')),
      isFalse,
    );
  });

  test('spots a server saying a model has no tool support', () {
    expect(
      ChatController.refusedTools(
        LlmException(
          'HTTP 404: {"error":{"message":"No endpoints found that support '
          'tool use. Try disabling \\"remember\\"."}}',
        ),
      ),
      isTrue,
    );
    expect(
      ChatController.refusedTools(LlmException('HTTP 401: bad key')),
      isFalse,
    );
  });
}
