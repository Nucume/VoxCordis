import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../app_scope.dart';
import '../../services/logs/app_log.dart';
import '../../theme/app_theme.dart';

/// Settings → Logs: what the browser, the web tools, the brain's thoughts
/// and tool calls, the replies and drawing did, newest first. Filter, copy,
/// save to a file or clear. The switch applies at once.
class LogsSettings extends StatefulWidget {
  const LogsSettings({super.key});

  @override
  State<LogsSettings> createState() => _LogsSettingsState();
}

class _LogsSettingsState extends State<LogsSettings> {
  static const _page = 150;

  /// Showing every kind when empty.
  final _kinds = <LogKind>{};
  var _limit = _page;
  var _errorsOnly = false;
  List<LogEntry>? _entries;
  AppLog? _log;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final log = AppScope.of(context).log;
    if (identical(log, _log)) return;
    _log?.removeListener(_load);
    _log = log..addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _log?.removeListener(_load);
    super.dispose();
  }

  Set<LogKind>? get _filter => _kinds.isEmpty ? null : _kinds;

  Future<void> _load() async {
    final all = await _log!.entries(
      kinds: _filter,
      errorsOnly: _errorsOnly,
      limit: _limit,
    );
    if (!mounted) return;
    setState(() => _entries = all);
  }

  void _toggleKind(LogKind k) {
    setState(() {
      if (!_kinds.remove(k)) _kinds.add(k);
      _limit = _page;
    });
    _load();
  }

  Future<void> _copy() async {
    final text = await _log!.asText(kinds: _filter, errorsOnly: _errorsOnly);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Logs copied'),
      ),
    );
  }

  Future<void> _save() async {
    final name =
        'voxcordis-logs-${DateFormat('yyyy-MM-dd-HHmm').format(DateTime.now())}.txt';
    final at = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Text', extensions: ['txt']),
      ],
    );
    if (at == null) return;
    final path = at.path.toLowerCase().endsWith('.txt')
        ? at.path
        : '${at.path}.txt';
    await File(path).writeAsString(
      await _log!.asText(kinds: _filter, errorsOnly: _errorsOnly),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text('Saved to $path'),
      ),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('Clear the logs?'),
        content: const SizedBox(
          width: 380,
          child: Text(
            'Every log line of this companion goes. Chats and memories '
            'stay as they are.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await _log!.clear();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).settings;
    final muted = context.palette.textMuted;
    final entries = _entries;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final s = store.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 14),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.keepLogs,
              onChanged: (on) => store.update(s.copyWith(keepLogs: on)),
              title: const Text('Keep logs'),
              subtitle: Text(
                'What ${s.companionName}\'s browser, web searches, thoughts, '
                'tool calls, replies and drawing did, to find out what went '
                'wrong. On this computer only, in ${s.companionName}\'s '
                'database (encrypted like the chat), with API keys blanked '
                'out. Never more than 7 days, ${AppLog.maxLines} lines or '
                '${AppLog.maxChars >> 20} MB: the oldest go first.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: s.keepLogs ? 1 : 0.45,
              child: IgnorePointer(
                ignoring: !s.keepLogs,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 6),
                    Text('What to keep', style: TextStyle(color: muted)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final k in LogKind.values)
                          FilterChip(
                            label: Text(k.label),
                            selected: !s.logsOff.contains(k.name),
                            onSelected: (on) => store.update(
                              s.copyWith(
                                logsOff: [
                                  for (final n in s.logsOff)
                                    if (n != k.name) n,
                                  if (!on) k.name,
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Show', style: TextStyle(color: muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in LogKind.values)
                  FilterChip(
                    label: Text(k.label),
                    selected: _kinds.contains(k),
                    onSelected: (_) => _toggleKind(k),
                  ),
                FilterChip(
                  avatar: const Icon(Icons.error_outline_rounded, size: 16),
                  label: const Text('Problems only'),
                  selected: _errorsOnly,
                  onSelected: (on) {
                    setState(() => _errorsOnly = on);
                    _load();
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
                OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: const Text('Save as file'),
                ),
                OutlinedButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (entries == null)
              const Center(child: CircularProgressIndicator())
            else if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  s.keepLogs
                      ? 'Nothing logged yet.'
                      : 'Logs are off, so nothing new is written.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
              )
            else ...[
              for (final e in entries) _LogTile(e, key: ValueKey(e.id)),
              if (entries.length >= _limit)
                Align(
                  child: TextButton(
                    onPressed: () {
                      setState(() => _limit += _page);
                      _load();
                    },
                    child: const Text('Show older'),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// One log line; a click shows its details.
class _LogTile extends StatefulWidget {
  const _LogTile(this.entry, {super.key});

  final LogEntry entry;

  @override
  State<_LogTile> createState() => _LogTileState();
}

class _LogTileState extends State<_LogTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final palette = context.palette;
    final now = DateTime.now();
    final today = DateUtils.isSameDay(e.at, now);
    final time = DateFormat(today ? 'HH:mm:ss' : 'd MMM HH:mm').format(e.at);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: palette.tile,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: e.details.isEmpty
              ? null
              : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        time,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 82,
                      child: Text(
                        e.kind.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: e.error ? scheme.error : scheme.primary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e.message,
                        style: TextStyle(
                          fontSize: 13,
                          color: e.error ? scheme.error : null,
                        ),
                      ),
                    ),
                    if (e.details.isNotEmpty)
                      Icon(
                        _open
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: palette.textMuted,
                      ),
                  ],
                ),
                if (_open)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: palette.codeFill,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        e.details,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
