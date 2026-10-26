import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_scope.dart';
import '../../data/schedule/schedule_repository.dart';
import '../../theme/app_theme.dart';

/// The companion's reminders and planned tasks, and what the tasks did:
/// see them, pause or delete them, or add one by hand.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  List<Schedule> _all = const [];
  List<ScheduleRun> _runs = const [];
  bool _loading = true;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    _services = AppScope.of(context)..scheduleRevision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _services?.scheduleRevision.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final s = _services!;
    final all = await s.schedules.all();
    final runs = await s.schedules.runs();
    if (!mounted) return;
    setState(() {
      _all = all;
      _runs = runs;
      _loading = false;
    });
  }

  Future<void> _edit([Schedule? existing]) async {
    final result = await showDialog<_Draft>(
      context: context,
      builder: (_) => _ScheduleDialog(
        existing: existing,
        companionName: _services!.settings.value.companionName,
      ),
    );
    if (result == null) return;
    final repo = _services!.schedules;
    if (existing == null) {
      await repo.add(
        kind: result.kind,
        text: result.text,
        at: result.at,
        repeat: result.repeat,
        origin: 'human',
      );
    } else {
      await repo.update(
        existing.id,
        kind: result.kind,
        text: result.text,
        at: result.at,
        repeat: result.repeat,
        active: true,
      );
    }
    _services!.scheduleChanged();
  }

  Future<void> _setActive(Schedule s, bool on) async {
    var at = s.nextAt;
    // Resuming something whose time passed: on to its next time, or an
    // hour from now for a one-off.
    if (on && !at.isAfter(DateTime.now())) {
      at = s.repeat.isOnce
          ? DateTime.now().add(const Duration(hours: 1))
          : s.repeat.next(s.nextAt, DateTime.now());
    }
    await _services!.schedules.update(s.id, active: on, at: at);
    _services!.scheduleChanged();
  }

  Future<void> _delete(Schedule s) async {
    await _services!.schedules.delete(s.id);
    _services!.scheduleChanged();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final name = services.settings.value.companionName;
    final palette = context.palette;
    final upcoming = [
      for (final s in _all)
        if (s.active) s,
    ];
    final paused = [
      for (final s in _all)
        if (!s.active) s,
    ];
    final byId = {for (final s in _all) s.id: s};
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Reminders and tasks',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add_alarm_rounded),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Ask $name in the chat ("remind me at 6 to call Mum", "every '
          'morning, check the weather for me"), or add one here. They '
          'happen while VoxCordis runs${services.settings.value.keepRunning ? '' : '; turn on Settings → General → Keep running so they also happen with the window closed'}.',
          style: TextStyle(fontSize: 12.5, color: palette.textMuted),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_all.isEmpty)
          _Empty(name: name)
        else ...[
          for (final s in upcoming)
            _ScheduleTile(
              item: s,
              onEdit: () => _edit(s),
              onToggle: () => _setActive(s, false),
              onDelete: () => _delete(s),
            ),
          if (paused.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'Paused and done',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: palette.textMuted,
              ),
            ),
            const SizedBox(height: 6),
            for (final s in paused)
              _ScheduleTile(
                item: s,
                onEdit: () => _edit(s),
                onToggle: () => _setActive(s, true),
                onDelete: () => _delete(s),
              ),
          ],
        ],
        if (_runs.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'Recent runs',
            style: TextStyle(fontWeight: FontWeight.w600, color: palette.text),
          ),
          const SizedBox(height: 6),
          for (final r in _runs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                r.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 18,
                color: r.ok ? palette.textMuted : Colors.orangeAccent,
              ),
              title: Text(
                byId[r.scheduleId]?.text ?? 'Deleted',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${DateFormat('EEE d MMM, HH:mm').format(r.startedAt)} · '
                '${r.summary.replaceAll('\n', ' ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
            ),
        ],
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(
      children: [
        Icon(Icons.alarm_rounded, size: 40, color: context.palette.textMuted),
        const SizedBox(height: 10),
        Text(
          'Nothing planned yet.',
          style: TextStyle(color: context.palette.textMuted),
        ),
      ],
    ),
  );
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({
    required this.item,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  final Schedule item;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final task = item.kind == ScheduleKind.task;
    final when = DateFormat('EEE d MMM, HH:mm').format(item.nextAt);
    final status = !item.active
        ? (item.origin == 'nemini' && item.lastRunAt == null
              ? 'Imported from Nemini · paused until you check it'
              : item.lastRunAt != null && item.repeat.isOnce
              ? 'Done'
              : 'Paused')
        : '$when · ${item.repeat.label}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Row(
        children: [
          Icon(
            task ? Icons.auto_mode_rounded : Icons.alarm_rounded,
            size: 20,
            color: item.active
                ? Theme.of(context).colorScheme.primary
                : palette.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.text, style: TextStyle(color: palette.text)),
                const SizedBox(height: 2),
                Text(
                  '${task ? 'Task' : 'Reminder'} · $status',
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 19),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: item.active ? 'Pause' : 'Resume',
            icon: Icon(
              item.active
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              size: 19,
            ),
            onPressed: onToggle,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded, size: 19),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _Draft {
  const _Draft(this.kind, this.text, this.at, this.repeat);

  final ScheduleKind kind;
  final String text;
  final DateTime at;
  final Repeat repeat;
}

class _ScheduleDialog extends StatefulWidget {
  const _ScheduleDialog({this.existing, required this.companionName});

  final Schedule? existing;
  final String companionName;

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late ScheduleKind _kind = widget.existing?.kind ?? ScheduleKind.reminder;
  late final _text = TextEditingController(text: widget.existing?.text);
  late DateTime _at = _start();
  late Repeat _repeat = widget.existing?.repeat ?? Repeat.once;

  static final _repeats = [
    Repeat.once,
    Repeat.daily,
    Repeat.weekdays,
    Repeat.weekly,
    Repeat.monthly,
    Repeat.hours(1),
    Repeat.hours(3),
  ];

  DateTime _start() {
    final e = widget.existing?.nextAt;
    if (e != null && e.isAfter(DateTime.now())) return e;
    final soon = DateTime.now().add(const Duration(hours: 1));
    return DateTime(soon.year, soon.month, soon.day, soon.hour);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _at.isBefore(now) ? now : _at,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365 * 3)),
    );
    if (d != null) {
      setState(
        () => _at = DateTime(d.year, d.month, d.day, _at.hour, _at.minute),
      );
    }
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (t != null) {
      setState(
        () => _at = DateTime(_at.year, _at.month, _at.day, t.hour, t.minute),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.companionName;
    final valid = _text.text.trim().isNotEmpty && _at.isAfter(DateTime.now());
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add to the plan' : 'Edit'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<ScheduleKind>(
              segments: const [
                ButtonSegment(
                  value: ScheduleKind.reminder,
                  icon: Icon(Icons.alarm_rounded),
                  label: Text('Reminder'),
                ),
                ButtonSegment(
                  value: ScheduleKind.task,
                  icon: Icon(Icons.auto_mode_rounded),
                  label: Text('Task'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.single),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _kind == ScheduleKind.reminder
                    ? 'Remind me to…'
                    : 'What should $name do?',
                hintText: _kind == ScheduleKind.reminder
                    ? 'call Mum'
                    : 'Check the weather and tell me if I need an umbrella',
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_rounded, size: 18),
                    label: Text(DateFormat('EEE d MMM y').format(_at)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule_rounded, size: 18),
                    label: Text(DateFormat('HH:mm').format(_at)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<Repeat>(
              dropdownColor: context.popupColor,
              borderRadius: BorderRadius.circular(14),
              initialValue: _repeats.contains(_repeat) ? _repeat : null,
              decoration: const InputDecoration(labelText: 'Repeat'),
              items: [
                for (final r in {..._repeats, _repeat})
                  DropdownMenuItem(value: r, child: Text(r.label)),
              ],
              onChanged: (r) => setState(() => _repeat = r ?? Repeat.once),
            ),
            if (_kind == ScheduleKind.task) ...[
              const SizedBox(height: 12),
              Text(
                '$name does this alone, with the web if Settings → Internet '
                'allows it, then tells you in the chat. Nothing that needs '
                'your OK happens while you are away.',
                style: TextStyle(
                  fontSize: 12,
                  color: context.palette.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid
              ? () => Navigator.pop(
                  context,
                  _Draft(_kind, _text.text.trim(), _at, _repeat),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
