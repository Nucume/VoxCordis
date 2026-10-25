import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_scope.dart';
import '../../data/memory/memory.dart';
import '../../data/memory/memory_repository.dart';
import '../../theme/app_theme.dart';

/// Everything the companion currently remembers, visible and editable.
///
/// Pinning sets priority 100, so the fact is in every prompt. Editing goes
/// through `update`, so the old wording stays in history.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  static const pinPriority = 100;

  final _search = TextEditingController();
  List<Memory> _all = const [];
  List<Memory> _forgotten = const [];
  bool _loading = true;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    _services = AppScope.of(context)..memoryRevision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _services?.memoryRevision.removeListener(_reload);
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final all = await _services!.memory.current();
    final forgotten = await _services!.memory.forgotten();
    if (!mounted) return;
    setState(() {
      _all = all;
      _forgotten = forgotten;
      _loading = false;
    });
  }

  List<Memory> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return [
      for (final m in _all)
        if ('${m.text} ${m.category} ${m.subject ?? ''} ${m.object ?? ''}'
            .toLowerCase()
            .contains(q))
          m,
    ];
  }

  Future<void> _togglePin(Memory m) async {
    final pinned = m.priority >= pinPriority;
    await _services!.memory.setPriority(m.id, pinned ? 50 : pinPriority);
    _services!.memoryChanged();
  }

  Future<void> _edit(Memory? m) async {
    final result = await showDialog<({String text, String category})>(
      context: context,
      builder: (_) => _EditDialog(memory: m),
    );
    if (result == null || result.text.trim().isEmpty) return;
    if (m == null) {
      await _services!.memory.remember(
        text: result.text.trim(),
        category: result.category,
        origin: 'user',
      );
    } else if (result.text.trim() != m.text || result.category != m.category) {
      await _services!.memory.update(
        m.id,
        text: result.text.trim(),
        category: result.category,
      );
    }
    _services!.memoryChanged();
  }

  Future<void> _forget(Memory m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this?'),
        content: Text(
          '"${m.text}"\n\nThis deletes it and its earlier versions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _services!.memory.forget(m.id);
    _services!.memoryChanged();
  }

  Future<void> _restore(Memory m) async {
    await _services!.memory.restore(m.id);
    _services!.memoryChanged();
  }

  Future<void> _deleteNow(Memory m) async {
    await _services!.memory.forget(m.id);
    _services!.memoryChanged();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final pinned = [
      for (final m in visible)
        if (m.priority >= pinPriority) m,
    ];
    final rest = [
      for (final m in visible)
        if (m.priority < pinPriority) m,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Search memories',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const SizedBox()
                : visible.isEmpty && _forgotten.isEmpty
                ? Center(
                    child: Text(
                      _all.isEmpty
                          ? 'Nothing remembered yet. Memories saved in chat show up here.'
                          : 'No memory matches.',
                      style: TextStyle(color: context.palette.textMuted),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 20),
                    children: [
                      if (pinned.isNotEmpty) ...[
                        const _Header('PINNED · ALWAYS IN MIND'),
                        for (final m in pinned) _tile(m),
                      ],
                      if (rest.isNotEmpty) ...[
                        _Header('REMEMBERED · ${rest.length}'),
                        for (final m in rest) _tile(m),
                      ],
                      if (_forgotten.isNotEmpty) ...[
                        _Header('RECENTLY FORGOTTEN · ${_forgotten.length}'),
                        for (final m in _forgotten)
                          _ForgottenTile(
                            key: ValueKey('forgotten-${m.id}'),
                            memory: m,
                            onRestore: () => _restore(m),
                            onDelete: () => _deleteNow(m),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(Memory m) => _MemoryTile(
    key: ValueKey(m.id),
    memory: m,
    pinned: m.priority >= pinPriority,
    onPin: () => _togglePin(m),
    onEdit: () => _edit(m),
    onForget: () => _forget(m),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 1.4,
        color: context.palette.textMuted,
      ),
    ),
  );
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({
    super.key,
    required this.memory,
    required this.pinned,
    required this.onPin,
    required this.onEdit,
    required this.onForget,
  });

  final Memory memory;
  final bool pinned;
  final VoidCallback onPin;
  final VoidCallback onEdit;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final m = memory;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      decoration: BoxDecoration(
        color: context.palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: pinned ? accent.withValues(alpha: 0.5) : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.text, style: const TextStyle(height: 1.35)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        m.category,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    _meta(
                      context,
                      'since ${DateFormat.yMMMd().format(m.validFrom.toLocal())}',
                    ),
                    if (m.reinforcedCount > 0)
                      _meta(context, 'came up ${m.reinforcedCount}×'),
                    if (m.origin != 'chat') _meta(context, m.origin),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: pinned ? 'Unpin' : 'Pin: always in mind',
            onPressed: onPin,
            color: pinned ? accent : context.palette.textMuted,
            icon: Icon(
              pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Edit',
            onPressed: onEdit,
            color: context.palette.textMuted,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Forget',
            onPressed: onForget,
            color: context.palette.textMuted,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  static Widget _meta(BuildContext context, String s) =>
      Text(s, style: TextStyle(fontSize: 11, color: context.palette.textMuted));
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({this.memory});
  final Memory? memory;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  static const _categories = [
    'general',
    'preference',
    'relationship',
    'project',
    'event',
    'identity',
  ];

  late final _text = TextEditingController(text: widget.memory?.text);
  late String _category = widget.memory?.category ?? 'general';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = {..._categories, _category}.toList();
    return AlertDialog(
      title: Text(widget.memory == null ? 'New memory' : 'Edit memory'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(hintText: 'One plain sentence'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in categories)
                  ChoiceChip(
                    label: Text(c),
                    selected: c == _category,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            if (widget.memory != null) ...[
              const SizedBox(height: 12),
              Text(
                'The old wording is kept in history.',
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
          onPressed: () =>
              Navigator.pop(context, (text: _text.text, category: _category)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// A fact the companion forgot: it can be brought back, or deleted now
/// instead of after [MemoryRepository.forgottenKeep].
class _ForgottenTile extends StatelessWidget {
  const _ForgottenTile({
    super.key,
    required this.memory,
    required this.onRestore,
    required this.onDelete,
  });

  final Memory memory;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final at = memory.forgottenAt!.toLocal();
    final gone = at.add(MemoryRepository.forgottenKeep);
    final day = DateFormat.MMMd();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        dense: true,
        title: Text(
          memory.text,
          style: TextStyle(
            color: context.palette.textMuted,
            decoration: TextDecoration.lineThrough,
          ),
        ),
        subtitle: Text(
          'Forgotten ${day.format(at)} · deleted for good ${day.format(gone)}',
          style: TextStyle(fontSize: 12, color: context.palette.textMuted),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: onRestore, child: const Text('Restore')),
            IconButton(
              tooltip: 'Delete now',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
