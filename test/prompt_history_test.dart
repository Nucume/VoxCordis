import 'dart:io';
import 'dart:math';

import 'package:companion/data/message_repository.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/prompt_history.dart';
import 'package:companion/services/llm_client.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _m(String role, String content) => ChatMessage(
  id: '$role-$content',
  ts: DateTime(2026),
  role: role,
  content: content,
);

String _roles(List<Map<String, Object?>> h) =>
    h.map((m) => m['role'] == 'user' ? 'u' : 'a').join();

void main() {
  test('starts with the human even when the window starts on a reply', () {
    final h = alternatingHistory([
      _m('assistant', 'hello'),
      _m('user', 'hi'),
      _m('assistant', 'how are you'),
      _m('user', 'good'),
    ]);
    expect(_roles(h), 'uau');
    expect(h.first['content'], 'hi');
  });

  test('joins messages left in a row by a failed send', () {
    final h = alternatingHistory([
      _m('user', 'first try'),
      _m('user', 'second try'),
    ]);
    expect(_roles(h), 'u');
    expect(h.single['content'], 'first try\n\nsecond try');
  });

  test('drops empty replies and other roles', () {
    final h = alternatingHistory([
      _m('user', 'a'),
      _m('assistant', ''),
      _m('tool', '{}'),
      _m('user', 'b'),
      _m('assistant', 'c'),
      _m('user', 'd'),
    ]);
    expect(_roles(h), 'uau');
    expect(h.first['content'], 'a\n\nb');
  });

  test('tool call ids become nine letters and digits', () {
    final kept = ToolCall('abc123XYZ', 'remember', '{}');
    expect(withShortId(kept), same(kept));
    final fixed = withShortId(
      ToolCall('call_0', 'remember', '{"t":1}'),
      Random(1),
    );
    expect(fixed.id, matches(RegExp(r'^[A-Za-z0-9]{9}$')));
    expect(fixed.name, 'remember');
    expect(fixed.arguments, '{"t":1}');
  });

  test('tells the companion who its human is', () {
    expect(
      aboutHuman(const AppSettings(userName: 'Sam', userPronouns: 'he/him')),
      endsWith('Their pronouns are he/him.'),
    );
    final sam = aboutHuman(const AppSettings(userName: 'Sam'));
    expect(sam, contains('every message in this chat is Sam talking to you'));
    expect(sam, contains('as "you"'));
    expect(aboutHuman(const AppSettings()), contains('ask when it fits'));
  });

  test('the prompt opens with who the companion is and how it writes', () {
    final text = howYouTalk(const AppSettings(companionName: 'Mira'));
    expect(text, startsWith('# You are Mira'));
    expect(text, contains('*like this*'));
    expect(text, contains('no name or label'));
    expect(text, contains('talking with your human'));
    expect(
      howYouTalk(const AppSettings(userName: 'Sam')),
      contains('talking with Sam in'),
    );
    expect(text, contains('not an assistant'));
  });

  test('tool notes quote what was saved on one line', () {
    expect(shortNote('  Likes\n tea '), 'Likes tea');
    expect(shortNote('x' * 100), hasLength(80));
    expect(shortNote('x' * 100), endsWith('…'));
  });

  test('Rocinante gets ChatML and its card\'s sampler settings', () {
    final m = ModelCatalog.models.firstWhere((m) => m.id == 'rocinante-12b');
    expect(m.chatTemplate, 'chatml-tools');
    expect(m.sampling['temperature'], 0.7);
  });

  test('Mistral Nemo gets our template, with the system prompt first', () {
    final nemo = ModelCatalog.models.firstWhere(
      (m) => m.id == 'mistral-nemo-12b',
    );
    expect(nemo.chatTemplate, 'mistral-nemo-tools');
    final template = File(
      'assets/chat_templates/mistral-nemo-tools.jinja',
    ).readAsStringSync();
    expect(template, contains('loop.first and system_message is defined'));
    expect(template, isNot(contains('loop.last and system_message')));
  });

  test('the time is a sentence, not a bare timestamp', () {
    final text = timeNote(DateTime(2026, 10, 24, 1, 44, 31));
    expect(text, startsWith('It is Saturday 24 October 2026, 01:44.'));
    expect(text, isNot(contains('01:44:31')));
  });

  test('catalog models keep their format; attached files use the pick', () {
    final rocinante = ModelCatalog.models.firstWhere(
      (m) => m.id == 'rocinante-12b',
    );
    final inCatalog = AppSettings(
      modelPath: '/m/${rocinante.file}',
      chatFormat: 'mistral',
    );
    expect(ChatFormat.templateFor(inCatalog), 'chatml-tools');
    const attached = AppSettings(modelPath: '/m/mine.gguf');
    expect(ChatFormat.templateFor(attached), isNull);
    expect(
      ChatFormat.templateFor(attached.copyWith(chatFormat: 'llama3')),
      'llama3-tools',
    );
  });

  test('a temperature the user sets wins over the card', () {
    final path =
        '/m/${ModelCatalog.models.firstWhere((m) => m.id == 'rocinante-12b').file}';
    expect(samplingFor(AppSettings(modelPath: path)), {
      'temperature': 0.7,
      'dry_multiplier': 0.8,
    });
    expect(samplingFor(AppSettings(modelPath: path, temperature: 1.1)), {
      'temperature': 1.1,
      'dry_multiplier': 0.8,
    });
    expect(
      samplingFor(AppSettings(modelPath: path, llmMode: LlmMode.external)),
      isEmpty,
    );
  });

  test('ChatML models stop at the end mark; others need no stop', () {
    final rocinante = ModelCatalog.models.firstWhere(
      (m) => m.id == 'rocinante-12b',
    );
    final path = '/models/${rocinante.file}';
    // Only the start of the mark, so broken ones stop the reply too.
    expect(stopFor(AppSettings(modelPath: path)), contains('<|im_'));
    expect(
      stopFor(AppSettings(modelPath: path, llmMode: LlmMode.external)),
      isEmpty,
    );
    expect(stopFor(const AppSettings(modelPath: '/models/own.gguf')), isEmpty);
  });

  test('repeated calls and extra computer requests are skipped', () {
    final seen = <String>{};
    ToolCall call(String name, String args) => ToolCall('x', name, args);
    final open = call('open', '{"target": "Pictures", "why": "a"}');
    expect(skipCall(open, seen: seen, askedHuman: false), isNull);
    expect(
      skipCall(open, seen: seen, askedHuman: true),
      contains('Already done'),
    );
    expect(
      skipCall(
        call('run_command', '{"command": "explorer Pictures"}'),
        seen: seen,
        askedHuman: true,
      ),
      contains('wait'),
    );
    expect(
      skipCall(
        call('remember', '{"text": "Likes tea"}'),
        seen: seen,
        askedHuman: true,
      ),
      contains('wait'),
    );
  });

  group('cutEndMark', () {
    test('cuts at a written-out end mark, broken ones too', () {
      for (final mark in [
        '<|im_end|>',
        '<|im_end|im_end|>',
        '<|im_end',
        '|im_end|>',
        'im_end|>',
        '<im_end>',
        '<|im_start|>user\nHi',
      ]) {
        expect(cutEndMark('*smiles* Hello. $mark more'), (
          text: '*smiles* Hello.',
          ended: true,
        ), reason: mark);
      }
    });

    test('holds back the start of a mark while it streams', () {
      expect(cutEndMark('Hello <|im'), (text: 'Hello ', ended: false));
      expect(cutEndMark('Hello <|'), (text: 'Hello ', ended: false));
      expect(cutEndMark('a < b and I imagine'), (
        text: 'a < b and I imagine',
        ended: false,
      ));
    });

    test('old replies lose the mark in the history sent to the model', () {
      expect(
        alternatingHistory([
          _m('user', 'Hi'),
          _m('assistant', 'Hey<|im_end|im_end|>'),
        ]),
        [
          {'role': 'user', 'content': 'Hi'},
          {'role': 'assistant', 'content': 'Hey'},
        ],
      );
    });
  });

  test('the prompt says how to open folders, or where to allow it', () {
    final on = aboutComputer(const AppSettings(systemAccess: true));
    expect(on, contains('target "Pictures"'));
    expect(on, contains('in that same reply'));
    final off = aboutComputer(const AppSettings());
    expect(off, contains('Settings → Computer'));
    expect(off, isNot(contains('run_command')));
  });

  test('plain requests to open a folder or address are recognised', () {
    for (final (text, target) in [
      (
        'Want to try open my File Explorer and point to something like my '
            'Pictures folder? :o',
        'Pictures',
      ),
      (
        '(OOC: This is a test. Open my File Explorer pointing to my Pictures '
            'directory)',
        'Pictures',
      ),
      ('can you pull up my downloads?', 'Downloads'),
      ('Open my photos please', 'Pictures'),
      ('open file explorer', 'Home'),
      ('Open https://example.com/a?b=1.', 'https://example.com/a?b=1'),
    ]) {
      expect(requestedOpen(text), target, reason: text);
    }
    for (final text in [
      'I\'d love to show you my pictures sometime',
      'my documents are a mess',
      'open up to me, how was your day?',
      'Look at https://example.com',
    ]) {
      expect(requestedOpen(text), isNull, reason: text);
    }
  });
}
