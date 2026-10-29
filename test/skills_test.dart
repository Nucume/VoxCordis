import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/desk/desk_tools.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/data/skills/builtin_skills.dart';
import 'package:companion/data/skills/skill_tools.dart';
import 'package:companion/data/skills/skills.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String folder;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skills');
    folder = p.join(tmp.path, 'Mira');
    await Directory(folder).create();
  });
  tearDown(() => tmp.delete(recursive: true));

  Skill byId(List<Skill> all, String id) => all.firstWhere((s) => s.id == id);

  test('the starter skills are written once, ADHD support off', () async {
    final skills = await Skills.load(folder);
    expect({for (final s in skills) s.id}, BuiltInSkills.ids);
    expect(byId(skills, 'weather').on, isTrue);
    expect(byId(skills, 'weather').problem, isNull);
    expect(byId(skills, 'adhd-support').on, isFalse);
    expect(byId(skills, 'adhd-support').always, isTrue);
    expect(byId(skills, 'price-watch').displayTitle, 'Price watch');

    // A deleted starter skill doesn't come back on the next load.
    await Skills.delete(folder, 'weather');
    final after = await Skills.load(folder);
    expect(after.any((s) => s.id == 'weather'), isFalse);
    await Skills.restoreBuiltIns(folder);
    expect(byId(await Skills.load(folder), 'weather').on, isTrue);
  });

  test('booru tags come with tag files, and replace the old version', () async {
    var booru = byId(await Skills.load(folder), 'booru-tags');
    expect(booru.on, isTrue);
    expect(booru.problem, isNull);
    expect(booru.files, containsAll(['guide.md', 'tags/lighting.md']));
    expect(booru.files.length, BuiltInSkills.booruTags.files.length);
    // The instructions fit a small memory span whole.
    expect(booru.body.length, lessThanOrEqualTo(Skills.bodyCharsFor(4096)));
    for (final f in booru.files) {
      expect(booru.body, contains(f.replaceAll('tags/', '')));
    }
    final used = Skills.forTool(booru, contextSize: 4096);
    expect(used['instructions'], isNot(contains('cut short')));
    expect(used['files'], contains('skills/booru-tags/tags/hair-styles.md'));

    // A companion from before: the old SKILL.md, untouched, gets replaced.
    final dir = Directory(p.join(folder, 'skills', 'booru-tags'));
    await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final md = File(p.join(dir.path, 'SKILL.md'));
    await md.writeAsString(BuiltInSkills.booruTags.older.first);
    booru = byId(await Skills.load(folder), 'booru-tags');
    expect(booru.description, BuiltInSkills.booruTags.description);
    expect(booru.files, contains('tags/sex-acts.md'));

    // One its human changed is theirs and stays.
    await dir.delete(recursive: true);
    await dir.create(recursive: true);
    await md.writeAsString(
      '${BuiltInSkills.booruTags.older.first}\n- My own rule.\n',
    );
    booru = byId(await Skills.load(folder), 'booru-tags');
    expect(booru.body, contains('My own rule.'));
    expect(booru.files, isEmpty);
  });

  test('parses Claude-style headers, quoted and folded', () {
    final parsed = Skills.parse(
      '---\n'
      'name: pdf\n'
      'description: >\n'
      '  Read PDFs and\n'
      '  fill forms.\n'
      'license: "Apache 2.0: see LICENSE"\n'
      'title: \'Mira\'\'s PDFs\'\n'
      '---\n'
      '# PDF\nSteps.',
    );
    expect(parsed.header['name'], 'pdf');
    expect(parsed.header['description'], 'Read PDFs and fill forms.');
    expect(parsed.header['license'], 'Apache 2.0: see LICENSE');
    expect(parsed.header['title'], "Mira's PDFs");
    expect(parsed.body.trim(), '# PDF\nSteps.');

    // What markdown() writes reads back the same.
    final again = Skills.parse(
      Skills.markdown(
        id: 'x',
        title: 'A "quoted" title',
        description: r'Has: colons \ and "quotes"',
        always: true,
        body: 'Do it.',
      ),
    );
    expect(again.header['title'], 'A "quoted" title');
    expect(again.header['description'], r'Has: colons \ and "quotes"');
    expect(again.header['always'], 'true');
  });

  test('saving, renaming and checking a skill', () async {
    expect(
      await Skills.save(
        folder,
        id: 'Plant Care',
        description: 'd',
        always: false,
        body: 'b',
      ),
      contains('small letters'),
    );
    expect(
      await Skills.save(
        folder,
        id: 'plant-care',
        title: 'Plant care',
        description: 'Look after plants.',
        always: false,
        body: 'Water them.',
      ),
      isNull,
    );
    var s = byId(await Skills.load(folder), 'plant-care');
    expect(s.on, isTrue, reason: 'a skill the human makes starts on');
    expect(s.body, 'Water them.');
    expect(s.builtIn, isFalse);

    expect(
      await Skills.save(
        folder,
        previousId: 'plant-care',
        id: 'plants',
        description: 'Look after plants.',
        always: false,
        body: 'Water them weekly.',
      ),
      isNull,
    );
    final all = await Skills.load(folder);
    expect(all.any((x) => x.id == 'plant-care'), isFalse);
    s = byId(all, 'plants');
    expect(s.on, isTrue);
    expect(s.body, 'Water them weekly.');

    expect(Skills.idFrom('Price Watch!'), 'price-watch');
  });

  test('a skill the companion writes waits for its human', () async {
    await Skills.load(folder);
    final settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
    );
    final desk = DeskTools(settings: () => settings);
    final wrote = jsonDecode(
      await desk.call('write_file', {
        'path': 'skills/knitting/SKILL.md',
        'content': Skills.markdown(
          id: 'knitting',
          description: 'Knitting patterns.',
          body: 'Count stitches.',
        ),
      }),
    );
    expect(wrote['ok'], isTrue);
    // It can't turn itself on.
    final refused = jsonDecode(
      await desk.call('write_file', {
        'path': 'skills/skills.json',
        'content': '{"on": ["knitting"]}',
      }),
    );
    expect(refused['ok'], isFalse);
    expect(
      jsonDecode(
        await desk.call('write_file', {
          'path': 'Skills/Skills.json.',
          'content': '{}',
        }),
      )['ok'],
      isFalse,
    );

    var knitting = byId(await Skills.load(folder), 'knitting');
    expect(knitting.review, isTrue);
    expect(knitting.on, isFalse);

    final tools = SkillTools(settings: () => settings);
    final off = jsonDecode(await tools.call('use_skill', {'name': 'knitting'}));
    expect(off['ok'], isFalse);
    expect(off['error'], contains('waits for your human'));
    final self = jsonDecode(
      await tools.call('switch_skill', {'name': 'knitting', 'on': true}),
    );
    expect(self['ok'], isFalse);

    await Skills.setOn(folder, 'knitting', true);
    knitting = byId(await Skills.load(folder), 'knitting');
    expect(knitting.review, isFalse);
    expect(knitting.on, isTrue);
    final used = jsonDecode(
      await tools.call('use_skill', {'name': 'knitting'}),
    );
    expect(used['ok'], isTrue);
    expect(used['instructions'], 'Count stitches.');

    final missing = jsonDecode(await tools.call('use_skill', {'name': 'nope'}));
    expect(missing['error'], contains('weather'));
  });

  test('the companion writes, switches and reads skills itself', () async {
    final settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
    );
    final tools = SkillTools(settings: () => settings);
    Future<Map> call(String name, Map<String, Object?> args) async =>
        jsonDecode(await tools.call(name, args)) as Map;

    var r = await call('write_skill', {
      'name': 'Plant Care',
      'description': 'Keeping houseplants alive.',
      'instructions': 'Water weekly.',
    });
    expect(r['ok'], isTrue);
    expect(r['skill'], 'plant-care');
    expect(r['note'], contains('waits for your human'));
    var plant = byId(await Skills.load(folder), 'plant-care');
    expect(plant.review, isTrue);
    expect(plant.on, isFalse);

    // Improving it keeps it waiting; one the human approved keeps its
    // switch and title.
    r = await call('write_skill', {
      'name': 'plant-care',
      'description': 'Keeping houseplants alive.',
      'instructions': 'Water weekly, less in winter.',
    });
    expect(byId(await Skills.load(folder), 'plant-care').review, isTrue);
    await Skills.setOn(folder, 'plant-care', true);
    r = await call('write_skill', {
      'name': 'weather',
      'description': 'Weather, in Celsius.',
      'instructions': 'Use wttr.in with ?m.',
    });
    final weather = byId(await Skills.load(folder), 'weather');
    expect(weather.on, isTrue);
    expect(weather.review, isFalse);
    expect(weather.body, 'Use wttr.in with ?m.');
    expect(
      (await call('write_skill', {'name': 'x', 'description': ''}))['ok'],
      isFalse,
    );

    // Off skills can still be read, and switched on and off.
    r = await call('switch_skill', {'name': 'weather', 'on': false});
    expect(r['ok'], isTrue);
    r = await call('use_skill', {'name': 'weather'});
    expect(r['ok'], isTrue);
    expect(r['note'], contains('switch_skill'));
    expect(byId(await Skills.load(folder), 'weather').on, isFalse);
    r = await call('switch_skill', {'name': 'weather', 'on': true});
    expect(byId(await Skills.load(folder), 'weather').on, isTrue);

    // Always-on ones are the human's.
    r = await call('switch_skill', {'name': 'adhd-support', 'on': true});
    expect(r['ok'], isFalse);
    expect(byId(await Skills.load(folder), 'adhd-support').on, isFalse);
  });

  test('at most ${Skills.maxOn} skills are on at once', () async {
    final settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
    );
    final tools = SkillTools(settings: () => settings);
    var on = (await Skills.load(folder)).where((s) => s.on).length;
    for (var i = 0; on < Skills.maxOn; i++, on++) {
      expect(
        await Skills.save(
          folder,
          id: 'extra-$i',
          description: 'Extra.',
          always: false,
          body: 'Do it.',
        ),
        isNull,
      );
    }
    expect((await Skills.load(folder)).where((s) => s.on).length, Skills.maxOn);
    // A new one the human makes now starts off, and can't be turned on.
    await Skills.save(
      folder,
      id: 'one-more',
      description: 'One more.',
      always: false,
      body: 'Do it.',
    );
    expect(byId(await Skills.load(folder), 'one-more').on, isFalse);
    expect(await Skills.setOn(folder, 'one-more', true), Skills.tooMany);
    final r = jsonDecode(
      await tools.call('switch_skill', {'name': 'one-more', 'on': true}),
    );
    expect(r['ok'], isFalse);
    expect(r['error'], contains('Turn one off first: '));
    expect(r['error'], contains('weather'));
    // Turning one off makes room.
    expect(await Skills.setOn(folder, 'weather', false), isNull);
    expect(await Skills.setOn(folder, 'one-more', true), isNull);
  });

  test('imports a SKILL.md folder, a Markdown file and a .skill zip', () async {
    // A folder with a script: the script stays behind.
    final src = Directory(p.join(tmp.path, 'src', 'pdf'))
      ..createSync(recursive: true);
    File(p.join(src.path, 'SKILL.md')).writeAsStringSync(
      '---\nname: pdf\ndescription: Work with PDFs.\n---\nUse forms.md.',
    );
    File(p.join(src.path, 'forms.md')).writeAsStringSync('Forms.');
    File(p.join(src.path, 'fill.py')).writeAsStringSync('print(1)');
    expect(await Skills.import(folder, p.join(src.path, 'SKILL.md')), 'pdf');
    var pdf = byId(await Skills.load(folder), 'pdf');
    expect(pdf.files, ['forms.md']);
    expect(pdf.on, isTrue);

    // The same name again gets a number.
    expect(await Skills.import(folder, p.join(src.path, 'SKILL.md')), 'pdf-2');

    // Plain Markdown without a header gets one.
    final md = File(p.join(tmp.path, 'Tea Ritual.md'))
      ..writeAsStringSync('Brew at 80 degrees.');
    expect(await Skills.import(folder, md.path), 'tea-ritual');
    final tea = byId(await Skills.load(folder), 'tea-ritual');
    expect(tea.problem, isNull);
    expect(tea.body, 'Brew at 80 degrees.');

    // A zip with the skill in a subfolder, and one entry trying to climb
    // out of it.
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'haiku/SKILL.md',
          '---\nname: haiku\ndescription: Write haiku.\n---\n5-7-5.',
        ),
      )
      ..add(ArchiveFile.string('haiku/../../evil.md', 'no'))
      ..add(ArchiveFile.string('haiku/ref/kigo.md', 'Seasons.'));
    final zip = File(p.join(tmp.path, 'haiku.skill'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    expect(await Skills.import(folder, zip.path), 'haiku');
    pdf = byId(await Skills.load(folder), 'haiku');
    expect(pdf.files, ['ref/kigo.md']);
    expect(File(p.join(tmp.path, 'evil.md')).existsSync(), isFalse);
    expect(File(p.join(folder, 'evil.md')).existsSync(), isFalse);

    await expectLater(
      Skills.import(folder, p.join(tmp.path, 'x.exe')),
      throwsA(isA<String>()),
    );
  });

  test(
    'the prompt lists skills that are on, and a called one in full',
    () async {
      await Skills.setOn(folder, 'adhd-support', true);
      final skills = await Skills.load(folder);
      expect(Skills.called('/weather in Bern', skills)?.id, 'weather');
      expect(Skills.called('/weatherman', skills), isNull);
      expect(Skills.called('what about /weather', skills), isNull);

      final text = Skills.forPrompt(
        skills,
        called: byId(skills, 'proofreading'),
        contextSize: 8192,
      );
      expect(text, contains('On (6 of ${Skills.maxOn}):'));
      expect(text, contains('- weather: Look up the weather'));
      expect(text, contains('write_skill'));
      expect(text, isNot(contains('A skill that fits')));
      // Always-on ones are there in full, not to pick.
      expect(text, isNot(contains('- adhd-support')));
      expect(text, contains('### ADHD support (always on)'));
      expect(text, contains('One thing at a time'));
      expect(text, contains('Skill called up now: Proofreading'));
      expect(text, contains('Keep their voice and meaning'));

      // Off ones by name; one that fits what was said in full.
      await Skills.setOn(folder, 'price-watch', false);
      final now = await Skills.load(folder);
      final fits = Skills.forPrompt(
        now,
        fits: byId(now, 'weather'),
        contextSize: 8192,
      );
      expect(fits, contains('Off for now: price-watch.'));
      expect(fits, isNot(contains('- price-watch')));
      expect(fits, contains('## A skill that fits: Weather'));
      expect(fits, contains('wttr.in'));
    },
  );

  test('typing a command calls up the skill for that reply', () async {
    final requests = <Map>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(jsonDecode(await utf8.decodeStream(req)) as Map);
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Fixed it.'},
            },
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await req.response.close();
    });
    final db = await openAppDatabase(inMemoryDatabasePath);
    final services = AppServices(
      settings: SettingsStore(
        File(p.join(tmp.path, 'settings.json')),
        AppSettings(
          companionName: 'Mira',
          companionFolder: folder,
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
    });

    final chat = ChatController(services);
    await chat.send('/proofreading teh cat sat');
    expect(chat.error, isNull);
    expect(chat.toolNote, 'Used the Proofreading skill');
    final system =
        ((requests.single['messages'] as List).first as Map)['content']
            as String;
    expect(system, contains('Skill called up now: Proofreading'));
    expect([
      for (final t in requests.single['tools'] as List) t['function']['name'],
    ], contains('use_skill'));
  });
}
