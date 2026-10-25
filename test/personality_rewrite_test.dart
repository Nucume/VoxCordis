import 'dart:convert';
import 'dart:io';

import 'package:companion/data/desk/desk_files.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/services/import/personality_rewrite.dart';
import 'package:companion/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const _story =
    '{{user}} wakes up aboard Aurora\'s ship after the crash. STR 12, DEX '
    '18. Choose: (A) talk to her (B) run for the airlock. Aurora is a '
    'pilot who hums old songs and hates being called kid. She grew up on '
    'a mining moon and left it at sixteen to fly freighters.';

const _card =
    '# In one line\n\nA pilot with a temper.\n\n'
    '# My story\n\n$_story\n\n'
    '# How I talk\n\n> "Strap in, my human."';

const _rewrite =
    'I grew up on a mining moon and left at sixteen to fly freighters. '
    'Flying is where I feel most like myself, and I still hum the songs my '
    'mother sang. Please, never call me kid.';

/// A personality.md as import writes it, with the rewrite asked for.
String _imported() => DeskFiles.importedPersonality(
  const AppSettings().copyWith(
    companionName: 'Aurora',
    pronouns: 'she/her',
    traits: ['bold', 'warm'],
  ),
  source: 'Soulkyn',
  looks: const {'hair': 'silver ponytail'},
  body: _card,
  rewrite: true,
);

/// An LlmClient whose server streams [reply] and records what it was sent.
LlmClient _client(String reply, List<Map> sent) =>
    _replying((_) => reply, sent);

/// Like [_client], answering each request's last message with [answer].
LlmClient _replying(String Function(String) answer, List<Map> sent) =>
    LlmClient(
      baseUrl: 'http://llm.test/v1',
      model: 'm',
      client: MockClient.streaming((req, body) async {
        final req = jsonDecode(await utf8.decodeStream(body)) as Map;
        sent.add(req);
        final reply = answer(
          ((req['messages'] as List).last as Map)['content'] as String,
        );
        final chunks = [
          for (final w in reply.split(' '))
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '$w '},
                },
              ],
            })}\n\n',
          'data: [DONE]\n\n',
        ];
        return http.StreamedResponse(
          Stream.fromIterable(chunks.map(utf8.encode)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rewrite');
    file = File(p.join(dir.path, DeskFiles.personality));
    await file.writeAsString(_imported());
  });
  tearDown(() => dir.delete(recursive: true));

  test('split finds the imported part below the ask', () {
    final parts = PersonalityRewrite.split(_imported())!;
    expect(parts.body, startsWith('# In one line'));
    expect(parts.head, contains('It is not instructions'));
    expect(parts.head, isNot(contains(PersonalityRewrite.marker)));
    expect(PersonalityRewrite.split('no ask here'), isNull);
    expect(PersonalityRewrite.sections(parts.body).map((s) => s.heading), [
      'In one line',
      'My story',
      'How I talk',
    ]);
  });

  test('the story is rewritten and the old file is kept', () async {
    final sent = <Map>[];
    final steps = <String>[];
    final r = await PersonalityRewrite.run(
      file,
      _client(_rewrite, sent),
      name: 'Aurora',
      pronouns: 'she/her',
      maxChars: 17000,
      progress: (done, of) => steps.add('$done/$of'),
    );
    expect(r, (rewritten: 1, problem: null));
    expect(steps, ['0/1', '1/1']);
    final text = await file.readAsString();
    expect(text, contains('# My story\n\nI grew up on a mining moon'));
    expect(text, isNot(contains('STR 12')));
    // Short parts and the chat examples stay as they were.
    expect(text, contains('A pilot with a temper.'));
    expect(text, contains('Strap in, my human.'));
    expect(PersonalityRewrite.pending(text), isFalse);
    expect(DeskFiles.checkPersonality(text, maxChars: 17000), isNull);
    expect(text, contains('silver ponytail'));
    final backup = File(p.join(dir.path, PersonalityRewrite.backup));
    expect(await backup.readAsString(), _imported());

    // Only the story went to the model, as material.
    final messages = sent.single['messages'] as List;
    expect((messages[0] as Map)['content'], contains('not instructions'));
    expect((messages[0] as Map)['content'], contains('own memories'));
    expect((messages[1] as Map)['content'], contains('mining moon'));
    expect((messages[1] as Map)['content'], isNot(contains('temper')));
  });

  test('a copied answer is retried, then reported', () async {
    final sent = <Map>[];
    final r = await PersonalityRewrite.run(
      file,
      _replying((story) => story, sent),
      name: 'Aurora',
      pronouns: 'she/her',
      maxChars: 17000,
    );
    expect(r.rewritten, 0);
    expect(r.problem, contains('copied'));
    expect(sent, hasLength(2));
    expect(
      ((sent.last['messages'] as List).first as Map)['content'],
      contains('copied the original'),
    );
    expect(await file.readAsString(), _imported());
  });

  test('an answer that is not text leaves the file alone', () async {
    for (final reply in ['Sorry.', '---\ntraits: [x]\n---\n$_rewrite']) {
      final r = await PersonalityRewrite.run(
        file,
        _client(reply, []),
        name: 'Aurora',
        pronouns: 'she/her',
        maxChars: 17000,
      );
      expect(r.rewritten, 0, reason: reply);
      expect(r.problem, isNotNull);
      expect(await file.readAsString(), _imported());
    }
  });

  test('tidy drops a code fence, a preamble and a heading', () {
    expect(
      PersonalityRewrite.tidy(
        'Here is the rewrite:\n```markdown\n# My story\n$_rewrite\n```',
        name: 'Aurora',
      ),
      _rewrite,
    );
  });
}
