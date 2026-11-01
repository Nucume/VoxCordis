import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/database_key.dart';
import '../../theme/app_theme.dart';

/// Settings → Privacy: chats set aside by "I lost the key" on the unlock
/// screen. With their key (one this computer kept, or the human's copy)
/// they are added back to today's chats.
class LockedChatsSection extends StatefulWidget {
  const LockedChatsSection({super.key});

  @override
  State<LockedChatsSection> createState() => _LockedChatsSectionState();
}

class _LockedChatsSectionState extends State<LockedChatsSection> {
  List<({Directory folder, String? kept})>? _found;
  final _fields = <String, TextEditingController>{};
  final _problems = <String, String>{};
  String? _busy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_found == null) _look();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _look() async {
    final key = AppScope.of(context).dbKey;
    final found = [
      for (final folder in key.lockedFolders())
        if (DatabaseKey.databasesIn(folder).isNotEmpty)
          (folder: folder, kept: await key.keptKeyFor(folder)),
    ];
    if (mounted) setState(() => _found = found);
  }

  Future<void> _bringBack(Directory folder, String? kept) async {
    final id = folder.path;
    final typed = _fields[id]?.text.trim() ?? '';
    final oldKey = kept ?? typed;
    if (oldKey.isEmpty) return;
    final dbs = DatabaseKey.databasesIn(folder);
    if (kept == null && !dbs.every((f) => DatabaseKey.opens(f, oldKey))) {
      setState(
        () => _problems[id] =
            "That key doesn't open these chats. Check for typos, or try "
            'an older copy.',
      );
      return;
    }
    setState(() {
      _busy = id;
      _problems.remove(id);
    });
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await services.bringBackLocked(folder, oldKey);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            n == 1 ? '1 message is back.' : '$n messages are back.',
          ),
        ),
      );
      if (mounted) {
        setState(() => _busy = null);
        await _look();
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _problems[id] = "They couldn't be brought back: $e";
      });
    }
  }

  static String _when(Directory folder) {
    final stamp = p
        .basename(folder.path)
        .substring(DatabaseKey.lockedPrefix.length);
    // locked-2026-11-01T07-12-30
    final m = RegExp(
      r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})',
    ).firstMatch(stamp);
    final t = m == null
        ? null
        : DateTime.tryParse('${m[1]}T${m[2]}:${m[3]}:${m[4]}');
    return t == null ? stamp : DateFormat('d MMM y, HH:mm').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    if (found == null || found.isEmpty) return const SizedBox.shrink();
    final palette = context.palette;
    final muted = TextStyle(
      fontSize: 12,
      color: palette.textMuted,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Text('Chats set aside', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          'These were moved aside when VoxCordis started over without '
          'their key. With the key they are added back to the chats and '
          'memories you have now; nothing you have now is lost.',
          style: muted,
        ),
        for (final (:folder, :kept) in found) ...[
          const SizedBox(height: 12),
          Text('Set aside ${_when(folder)}'),
          const SizedBox(height: 6),
          if (kept != null)
            Text(
              'VoxCordis still has their key, so they can come back as '
              'they are.',
              style: muted,
            )
          else
            TextField(
              controller: _fields.putIfAbsent(
                folder.path,
                TextEditingController.new,
              ),
              obscureText: true,
              enabled: _busy == null,
              onSubmitted: (_) => _bringBack(folder, kept),
              decoration: InputDecoration(
                labelText: 'Key or password from back then',
                errorText: _problems[folder.path],
                errorMaxLines: 3,
              ),
            ),
          if (kept != null && _problems[folder.path] != null)
            Text(
              _problems[folder.path]!,
              style: muted.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _busy == null ? () => _bringBack(folder, kept) : null,
              icon: _busy == folder.path
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restore_rounded),
              label: const Text('Bring them back'),
            ),
          ),
        ],
      ],
    );
  }
}
