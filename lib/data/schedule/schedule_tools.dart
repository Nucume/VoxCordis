import 'dart:convert';

import 'schedule_repository.dart';

/// Tools for reminders and tasks: set one, list them, cancel one. The
/// [Scheduler] makes them happen while VoxCordis runs.
class ScheduleTools {
  ScheduleTools(this.repo, {this.onChanged, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final ScheduleRepository repo;

  /// Called after anything changed, so the Reminders tab reloads.
  final void Function()? onChanged;
  final DateTime Function() _clock;

  static const names = {
    'set_reminder',
    'schedule_task',
    'list_schedule',
    'cancel_schedule',
  };

  static const _when = {
    'type': 'string',
    'description':
        'Local date and time like "2026-11-02 18:30", or "in 20 minutes", '
        '"in 3 hours", "tomorrow 9:00", "18:30" (the next time it is 18:30).',
  };
  static const _repeat = {
    'type': 'string',
    'description':
        'Leave out for once. Or: daily, weekdays, weekly, monthly, "every 2 '
        'hours", "every 30 minutes".',
  };

  static List<Map<String, Object?>> get definitions => [
    {
      'type': 'function',
      'function': {
        'name': 'set_reminder',
        'description':
            'Remind your human of something at a time. When it is due you '
            'tell them in the chat, and they get a notification.',
        'parameters': {
          'type': 'object',
          'properties': {
            'when': _when,
            'text': {
              'type': 'string',
              'description': 'What to remind them of, e.g. "call Mum".',
            },
            'repeat': _repeat,
          },
          'required': ['when', 'text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'schedule_task',
        'description':
            'Plan a job you do yourself later, on your own, then tell your '
            'human what you found: e.g. "check the weather in Zurich and '
            'tell them if they need an umbrella", "sum up the news about '
            'X". Use it when they ask you to do something at a time or '
            'regularly.',
        'parameters': {
          'type': 'object',
          'properties': {
            'when': _when,
            'task': {
              'type': 'string',
              'description': 'What to do, written as a note to yourself.',
            },
            'repeat': _repeat,
          },
          'required': ['when', 'task'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_schedule',
        'description': 'List your upcoming reminders and tasks, with ids.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'cancel_schedule',
        'description': 'Cancel a reminder or task by its id.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': 'From list_schedule.'},
          },
          'required': ['id'],
        },
      },
    },
  ];

  Future<String> call(String name, Map<String, Object?> args) async {
    try {
      final result = switch (name) {
        'set_reminder' => await _add(ScheduleKind.reminder, args, 'text'),
        'schedule_task' => await _add(ScheduleKind.task, args, 'task'),
        'list_schedule' => {
          'ok': true,
          'now': _clockText(),
          'items': [for (final s in await repo.upcoming()) s.toJson()],
        },
        'cancel_schedule' => await _cancel('${args['id'] ?? ''}'),
        _ => throw 'unknown tool $name',
      };
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  String _clockText() => Schedule.stamp(_clock());

  Future<Map<String, Object?>> _add(
    ScheduleKind kind,
    Map<String, Object?> args,
    String textKey,
  ) async {
    final text = '${args[textKey] ?? ''}'.trim();
    if (text.isEmpty) throw '"$textKey" is empty';
    final now = _clock();
    final at = parseWhen('${args['when'] ?? ''}', now);
    if (at == null) {
      throw 'Could not read "when". Write it like "2026-11-02 18:30" or '
          '"in 20 minutes". It is ${_clockText()} now.';
    }
    if (!at.isAfter(now.subtract(const Duration(minutes: 1)))) {
      throw '${Schedule.stamp(at)} has passed. It is ${_clockText()} now.';
    }
    final repeat = Repeat.parse(args['repeat']);
    if (repeat == null) {
      throw 'Could not read "repeat": use daily, weekdays, weekly, monthly '
          'or "every N hours".';
    }
    final s = await repo.add(kind: kind, text: text, at: at, repeat: repeat);
    onChanged?.call();
    return {'ok': true, 'scheduled': s.toJson()};
  }

  Future<Map<String, Object?>> _cancel(String id) async {
    final s = await repo.find(id);
    if (s == null) throw 'No reminder or task with id "$id".';
    await repo.delete(s.id);
    onChanged?.call();
    return {'ok': true, 'cancelled': s.toJson()};
  }

  /// Reads a time the way people and models write it, relative to [now]:
  /// `2026-11-02 18:30` (or with a T, seconds, or a zone), `in 20
  /// minutes`, `in 2 hours`, `in 3 days`, `tomorrow 9:00`, `today 18:00`,
  /// `18:30` or `6:30 pm` (the next time it is). Null when it can't.
  static DateTime? parseWhen(String raw, DateTime now) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) return null;
    final rel = RegExp(
      r'^in\s+(\d+|an?|one)\s*(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?|w|weeks?)$',
    ).firstMatch(t);
    if (rel != null) {
      final n = int.tryParse(rel[1]!) ?? 1;
      final u = rel[2]!;
      return now.add(switch (u[0]) {
        's' => Duration(seconds: n),
        'm' => Duration(minutes: n),
        'h' => Duration(hours: n),
        'd' => Duration(days: n),
        _ => Duration(days: 7 * n),
      });
    }
    final iso = DateTime.tryParse(raw.trim().replaceFirst(' ', 'T'));
    if (iso != null && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(raw.trim())) {
      return iso.isUtc || RegExp(r'[+-]\d{2}:?\d{2}$|z$').hasMatch(t)
          ? iso.toLocal()
          : iso;
    }
    final m = RegExp(
      r'^(today|tomorrow|tonight)?\s*(?:at\s+)?(\d{1,2})(?:[:.h](\d{2}))?\s*(am|pm)?$',
    ).firstMatch(t);
    if (m == null || (m[3] == null && m[4] == null && m[1] == null)) {
      return null;
    }
    var hour = int.parse(m[2]!);
    final minute = int.tryParse(m[3] ?? '') ?? 0;
    if (m[4] == 'pm' && hour < 12) hour += 12;
    if (m[4] == 'am' && hour == 12) hour = 0;
    if (m[1] == 'tonight' && m[4] == null && hour < 12) hour += 12;
    if (hour > 23 || minute > 59) return null;
    var at = DateTime(now.year, now.month, now.day, hour, minute);
    if (m[1] == 'tomorrow') {
      at = DateTime(now.year, now.month, now.day + 1, hour, minute);
    } else if (m[1] == null && !at.isAfter(now)) {
      at = DateTime(now.year, now.month, now.day + 1, hour, minute);
    }
    return at;
  }
}
