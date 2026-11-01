import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/desk/desk_files.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/features/chat/edit_lesson.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fake server: a request about a rewrite gets [lesson], any other one
/// a long-winded reply.
Future<(HttpServer, List<Map>)> _mockLlm(String lesson) async {
  final requests = <Map>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = jsonDecode(await utf8.decodeStream(req)) as Map;
    requests.add(body);
    final system = ((body['messages'] as List).first as Map)['content'];
    final text = '$system'.contains('rewrote one of')
        ? lesson
        : 'Well, there are many teas, and honestly it depends on a great '
              'many things, but I would say green tea is lovely.';
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.write(
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      })}\n\n',
    );
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  return (server, requests);
}

Future<(AppServices, List<Map>)> _services(String lesson) async {
  final (server, requests) = await _mockLlm(lesson);
  final tmp = await Directory.systemTemp.createTemp('edit_lesson');
  final db = await openAppDatabase(inMemoryDatabasePath);
  final services = AppServices(
    settings: SettingsStore(
      File('${tmp.path}/settings.json'),
      AppSettings(
        companionName: 'Aria',
        userName: 'Haru',
        companionFolder: '${tmp.path}/Aria',
        llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
        llmMode: LlmMode.external,
        llmModel: 'mock',
      ),
    ),
    db: db,
    dbKey: DatabaseKey(Directory.systemTemp),
    runtime: RuntimeController(tmp),
  );
  addTearDown(() async {
    await server.close(force: true);
    await db.close();
    await tmp.delete(recursive: true);
  });
  return (services, requests);
}

/// Waits until the lesson is worked out.
Future<void> _settle(ChatController chat) async {
  for (var i = 0; i < 200 && (chat.lessonOffer?.thinking ?? false); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('only real changes are worth learning from', () {
    expect(EditLesson.worthLearning('Hello there!', 'hello, there.'), isFalse);
    expect(EditLesson.worthLearning('Hi  there', 'Hi there'), isFalse);
    expect(EditLesson.worthLearning('Hi there', 'Hey you'), isTrue);
  });

  test('the answer is read even from a small model', () {
    expect(
      EditLesson.parse('RULE: Keep replies short.\nWHY: Haru likes it brief'),
      (rule: 'Keep replies short', why: 'Haru likes it brief'),
    );
    // Markdown, quotes and a missing reason.
    expect(EditLesson.parse('**Rule:** "Use **casual** words"'), (
      rule: 'Use casual words',
      why: 'my human rewrote my reply',
    ));
    expect(EditLesson.parse('NONE'), isNull);
    expect(EditLesson.parse('RULE: none'), isNull);
    expect(EditLesson.parse('I think they want shorter replies.'), isNull);
    // Too long for a lesson line: cut at a word.
    final long = EditLesson.parse('RULE: ${'word ' * 40}\nWHY: ${'x ' * 40}')!;
    expect(long.rule.length, lessThanOrEqualTo(EditLesson.maxRule));
    expect(long.rule.endsWith('word'), isTrue);
    expect(
      DeskFiles.lessonLine(long.rule, long.why, DateTime(2026)).length,
      lessThan(DeskFiles.lessonMaxChars),
    );
  });

  test('pictures and files stay with an edited message', () {
    expect(
      EditLesson.withMarkersOf('Look!\n\n[image: images/a.png]', 'See this'),
      'See this\n\n[image: images/a.png]',
    );
    expect(EditLesson.withMarkersOf('Plain', 'New'), 'New');
  });

  test('an edited reply is kept and offers a lesson to keep', () async {
    final (services, requests) = await _services(
      'RULE: Keep replies short and direct\nWHY: Haru likes it brief',
    );
    final chat = ChatController(services);
    await chat.send('Which tea should I try?');
    final reply = chat.messages.last;
    expect(reply.role, 'assistant');

    await chat.editReply(reply, 'Try genmaicha.');
    expect(chat.messages.last.content, 'Try genmaicha.');
    expect((await services.messages.recent()).last.content, 'Try genmaicha.');
    expect(chat.lessonOffer?.messageId, reply.id);

    await _settle(chat);
    expect(chat.lessonOffer?.rule, 'Keep replies short and direct');
    expect(chat.lessonOffer?.why, 'Haru likes it brief');
    // The model saw both versions and the question.
    final asked = jsonEncode(requests.last['messages']);
    expect(asked, contains('Which tea should I try?'));
    expect(asked, contains('many teas'));
    expect(asked, contains('Try genmaicha.'));
    expect(requests.last.containsKey('tools'), isFalse);

    // Reworded by the human, then kept.
    expect(await chat.keepLesson(rule: 'Keep replies short'), isNull);
    expect(chat.lessonOffer, isNull);
    final lessons = await File(
      '${services.settings.value.companionFolder}/${DeskFiles.lessons}',
    ).readAsString();
    expect(lessons, contains('- **Keep replies short** — Haru likes it brief'));

    // The next turn sees the edited reply.
    await chat.send('Thanks');
    final history = jsonEncode(requests.last['messages']);
    expect(history, contains('Try genmaicha.'));
    expect(history, isNot(contains('many teas')));
    expect(history, contains('Keep replies short'));
  });

  test('a fixed comma or NONE offers nothing', () async {
    final (services, requests) = await _services('NONE');
    final chat = ChatController(services);
    await chat.send('Which tea?');
    final reply = chat.messages.last;
    final asked = requests.length;

    await chat.editReply(reply, '${reply.content}!');
    expect(chat.lessonOffer, isNull);
    expect(requests.length, asked);

    await chat.editReply(chat.messages.last, 'Genmaicha.');
    await _settle(chat);
    expect(chat.lessonOffer, isNull);
    expect(chat.toolNote, 'Nothing new to learn from that edit');
  });

  test('skipping drops the offer', () async {
    final (services, _) = await _services('RULE: Be brief\nWHY: short');
    final chat = ChatController(services);
    await chat.send('Hi');
    await chat.editReply(chat.messages.last, 'Hey.');
    await _settle(chat);
    expect(chat.lessonOffer?.rule, 'Be brief');
    chat.skipLesson();
    expect(chat.lessonOffer, isNull);
  });
}
