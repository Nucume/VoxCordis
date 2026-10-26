import 'dart:convert';

import 'package:companion/data/database.dart';
import 'package:companion/data/schedule/schedule_repository.dart';
import 'package:companion/data/schedule/schedule_tools.dart';
import 'package:companion/services/schedule/scheduler.dart';
import 'package:companion/services/system/background.dart';
import 'package:companion/services/system/desktop_notifier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // A Thursday afternoon.
  final now = DateTime(2026, 10, 29, 15, 20);

  group('Repeat', () {
    test('reads everyday words', () {
      expect(Repeat.parse(null), Repeat.once);
      expect(Repeat.parse('every day'), Repeat.daily);
      expect(Repeat.parse('Weekdays'), Repeat.weekdays);
      expect(Repeat.parse('weekly'), Repeat.weekly);
      expect(Repeat.parse('every 2 hours'), Repeat.hours(2));
      expect(Repeat.parse('hours:3'), Repeat.hours(3));
      expect(Repeat.parse('every 5 minutes'), Repeat.minutes(15));
      expect(Repeat.parse('whenever'), isNull);
    });

    test('finds the next time at the same time of day', () {
      final at8 = DateTime(2026, 10, 1, 8);
      expect(Repeat.daily.next(at8, now), DateTime(2026, 10, 30, 8));
      // Friday 8:00 is next; after it, the Monday.
      expect(Repeat.weekdays.next(at8, now), DateTime(2026, 10, 30, 8));
      expect(
        Repeat.weekdays.next(at8, DateTime(2026, 10, 30, 9)),
        DateTime(2026, 11, 2, 8),
      );
      // 1 October 2026 is a Thursday.
      expect(Repeat.weekly.next(at8, now), DateTime(2026, 11, 5, 8));
      expect(Repeat.monthly.next(at8, now), DateTime(2026, 11, 1, 8));
      expect(
        Repeat.monthly.next(DateTime(2026, 1, 31, 8), DateTime(2026, 2, 2)),
        DateTime(2026, 2, 28, 8),
      );
      expect(
        Repeat.hours(3).next(DateTime(2026, 10, 29, 9), now),
        DateTime(2026, 10, 29, 18),
      );
    });
  });

  group('parseWhen', () {
    DateTime? when(String s) => ScheduleTools.parseWhen(s, now);

    test('reads times the way they are written', () {
      expect(when('in 20 minutes'), DateTime(2026, 10, 29, 15, 40));
      expect(when('in an hour'), DateTime(2026, 10, 29, 16, 20));
      expect(when('in 2 days'), DateTime(2026, 10, 31, 15, 20));
      expect(when('2026-11-02 18:30'), DateTime(2026, 11, 2, 18, 30));
      expect(when('2026-11-02T18:30:00'), DateTime(2026, 11, 2, 18, 30));
      expect(when('18:30'), DateTime(2026, 10, 29, 18, 30));
      // Already past today: tomorrow.
      expect(when('9:00'), DateTime(2026, 10, 30, 9));
      expect(when('tomorrow 9:00'), DateTime(2026, 10, 30, 9));
      expect(when('6:30 pm'), DateTime(2026, 10, 29, 18, 30));
      expect(when('tonight at 8'), DateTime(2026, 10, 29, 20));
      expect(when('soonish'), isNull);
      expect(when('25:00'), isNull);
    });
  });

  group('tools and scheduler', () {
    late Database db;
    late ScheduleRepository repo;
    late ScheduleTools tools;
    var clock = now;

    setUp(() async {
      db = await openAppDatabase(inMemoryDatabasePath);
      repo = ScheduleRepository(db);
      clock = now;
      tools = ScheduleTools(repo, clock: () => clock);
    });

    tearDown(() => db.close());

    Future<Map> call(String name, Map<String, Object?> args) async =>
        jsonDecode(await tools.call(name, args)) as Map;

    test('set, list and cancel', () async {
      final set = await call('set_reminder', {
        'when': 'in 10 minutes',
        'text': 'stretch',
        'repeat': 'every 2 hours',
      });
      expect(set['ok'], true);
      final listed = await call('list_schedule', {});
      expect(listed['items'], [
        {
          'id': (set['scheduled'] as Map)['id'],
          'kind': 'reminder',
          'text': 'stretch',
          'when': '2026-10-29 15:30',
          'repeat': 'every 2 hours',
        },
      ]);
      final past = await call('schedule_task', {
        'when': '2026-10-01 08:00',
        'task': 'x',
      });
      expect(past['ok'], false);
      expect(past['error'], contains('has passed'));
      final gone = await call('cancel_schedule', {
        'id': (set['scheduled'] as Map)['id'],
      });
      expect(gone['ok'], true);
      expect(await repo.all(), isEmpty);
    });

    test('runs what is due, moves repeats on, and caps tasks', () async {
      final ran = <String>[];
      final notified = <String>[];
      var busy = false;
      final scheduler = Scheduler(
        repo: () => repo,
        run: (s, {required late}) async {
          if (busy) return null;
          ran.add('${s.text}${late ? ' (late)' : ''}');
          return ScheduledOutcome(ok: true, text: 'Done: ${s.text}');
        },
        runsPerDay: () => 2,
        notify: (title, body) async => notified.add(body),
        focused: () async => false,
        clock: () => clock,
      );
      await repo.add(
        kind: ScheduleKind.reminder,
        text: 'tea',
        at: now.add(const Duration(minutes: 1)),
      );
      await repo.add(
        kind: ScheduleKind.task,
        text: 'news',
        at: now.subtract(const Duration(hours: 5)),
        repeat: Repeat.hours(1),
      );
      await scheduler.tick();
      // Missed while closed: once, late, then on to the next hour.
      expect(ran, ['news (late)']);
      final news = (await repo.all()).firstWhere((s) => s.text == 'news');
      expect(news.nextAt, DateTime(2026, 10, 29, 16, 20));

      // Busy writing a reply: nothing happens until the next tick.
      clock = now.add(const Duration(minutes: 2));
      busy = true;
      await scheduler.tick();
      expect(ran, ['news (late)']);
      busy = false;
      await scheduler.tick();
      expect(ran, ['news (late)', 'tea']);
      expect(notified, ['Done: news', 'Done: tea']);
      final tea = (await repo.all()).firstWhere((s) => s.text == 'tea');
      expect(tea.active, isFalse);

      // Two runs today already: the next task run is skipped and logged.
      clock = news.nextAt.add(const Duration(minutes: 1));
      await scheduler.tick();
      expect(ran, hasLength(2));
      final runs = await repo.runs();
      expect(runs.first.ok, isFalse);
      expect(runs.first.summary, contains('limit'));
    });
  });

  test('the autostart entry quotes the command', () {
    final entry = Background.linuxAutostartEntry(
      r'/home/a b/Vox"Cordis$.AppImage',
    );
    expect(
      entry,
      contains(r'Exec="/home/a b/Vox\"Cordis\$.AppImage" --background'),
    );
  });

  test('gdbus strings are escaped', () {
    expect(DesktopNotifier.gvariantString('say "hi"\n\\'), r'"say \"hi\"\n\\"');
  });
}
