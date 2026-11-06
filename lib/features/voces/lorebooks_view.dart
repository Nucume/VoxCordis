import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/voces/lore_match.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../theme/app_theme.dart';
import 'voces_editor.dart';
import 'voces_home.dart';
import 'voces_widgets.dart';

/// The Lorebooks tab: every book, its entries, and a box to try a line of
/// story against them; the entries it would bring into the prompt light up.
class LorebooksView extends StatefulWidget {
  const LorebooksView({
    super.key,
    required this.data,
    required this.selected,
    required this.onSelect,
    this.tryText,
  });

  final VocesData data;
  final String? selected;
  final ValueChanged<String?> onSelect;

  /// A line to try straight away (search jumped to an entry).
  final String? tryText;

  @override
  State<LorebooksView> createState() => _LorebooksViewState();
}

class _LorebooksViewState extends State<LorebooksView> {
  late final _try = TextEditingController(text: widget.tryText);

  @override
  void dispose() {
    _try.dispose();
    super.dispose();
  }

  Future<void> _newBook() async {
    final name = await _askName(context, 'New lorebook', '');
    if (name == null) return;
    final book = await widget.data.library.saveLorebook(
      Lorebook(id: '', name: name),
    );
    await widget.data.reload();
    widget.onSelect(book.id);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final book =
        (widget.selected == null ? null : data.lorebook(widget.selected!)) ??
        data.lorebooks.firstOrNull;
    return LayoutBuilder(
      builder: (context, box) => Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              // Narrower in a small window, so the book keeps its room.
              width: (box.maxWidth * 0.34).clamp(170.0, 240.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Lorebooks',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: palette.text,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'New lorebook',
                        onPressed: _newBook,
                        icon: const Icon(Icons.library_add_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final b in data.lorebooks)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => widget.onSelect(b.id),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: b.id == book?.id
                                      ? accent.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                  border: Border.all(
                                    color: b.id == book?.id
                                        ? accent.withValues(alpha: 0.45)
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      b.name,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: palette.text,
                                      ),
                                    ),
                                    Text(
                                      _bookMeta(b, data),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: palette.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (data.lorebooks.isEmpty)
                          Text(
                            'No lorebooks yet. Make one, or import one: many '
                            'character cards bring their own.',
                            style: TextStyle(color: palette.textMuted),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: book == null
                  ? const SizedBox()
                  : _Book(
                      key: ValueKey(book.id),
                      book: book,
                      data: data,
                      tryLine: _try,
                      onDeleted: () => widget.onSelect(null),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _bookMeta(Lorebook b, VocesData data) {
    final worlds = data.worlds
        .where((w) => w.lorebookIds.contains(b.id))
        .length;
    return '${b.entries.length} ${b.entries.length == 1 ? 'entry' : 'entries'}'
        ' · ${worlds == 1 ? '1 world' : '$worlds worlds'}';
  }
}

class _Book extends StatelessWidget {
  const _Book({
    super.key,
    required this.book,
    required this.data,
    required this.tryLine,
    required this.onDeleted,
  });

  final Lorebook book;
  final VocesData data;
  final TextEditingController tryLine;
  final VoidCallback onDeleted;

  Future<void> _save(Lorebook b) async {
    await data.library.saveLorebook(b);
    await data.reload();
  }

  Future<void> _rename(BuildContext context) async {
    final name = await _askName(context, 'Rename lorebook', book.name);
    if (name != null) await _save(book.copyWith(name: name));
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete ${book.name}?',
      body:
          'Its ${book.entries.length} entries go too, and worlds using it '
          'lose it. Stories already started keep their own copy.',
    );
    if (!ok) return;
    for (final w in data.worlds) {
      if (w.lorebookIds.contains(book.id)) {
        await data.library.saveWorld(
          w.copyWith(lorebookIds: [...w.lorebookIds]..remove(book.id)),
        );
      }
    }
    await data.library.deleteLorebook(book.id);
    onDeleted();
    await data.reload();
  }

  Future<void> _edit(BuildContext context, int? index) async {
    final result = await openEditor<_EntryResult>(
      context,
      (done) => _EntryEditor(data: data, book: book, index: index, done: done),
    );
    if (result == null) return;
    final entries = [...book.entries];
    switch (result) {
      case _Deleted():
        if (index != null) entries.removeAt(index);
      case _Saved(:final entry):
        if (index == null) {
          entries.add(entry);
        } else {
          entries[index] = entry;
        }
    }
    await _save(book.copyWith(entries: entries));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final glow = const Color(0xFFFFC88C);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          runSpacing: 6,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160),
              child: Text(
                book.name,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: palette.text,
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Rename',
                  onPressed: () => _rename(context),
                  icon: const Icon(Icons.drive_file_rename_outline_rounded),
                ),
                IconButton(
                  tooltip: 'Delete lorebook',
                  onPressed: () => _delete(context),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  onPressed: () => _edit(context, null),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New entry'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        VocesBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const VocesLabel('Try it · type a line from a story'),
              const SizedBox(height: 8),
              TextField(
                controller: tryLine,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'e.g. Is the lighthouse lit tonight?',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListenableBuilder(
            listenable: tryLine,
            builder: (context, _) {
              final line = tryLine.text.trim();
              final lit = line.length < 3
                  ? const <LoreEntry>{}
                  : LoreMatch.match(line, book.entries).toSet();
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      line.length < 3
                          ? 'Entries a line would bring into the prompt light up.'
                          : lit.isEmpty
                          ? 'Nothing here would come in for that line.'
                          : '${lit.length} of ${book.entries.length} would come in.',
                      style: TextStyle(fontSize: 12, color: palette.textMuted),
                    ),
                  ),
                  for (var i = 0; i < book.entries.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _edit(context, i),
                        child: Opacity(
                          opacity: book.entries[i].enabled ? 1 : 0.5,
                          child: VocesBox(
                            highlight: lit.contains(book.entries[i])
                                ? glow
                                : null,
                            child: _EntryTile(
                              entry: book.entries[i],
                              glow: glow,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (book.entries.isEmpty)
                    Text(
                      'No entries yet. An entry is a few key words and the '
                      'text that joins the story when they come up.',
                      style: TextStyle(color: palette.textMuted),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.glow});

  final LoreEntry entry;
  final Color glow;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              entry.title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
            const SizedBox(width: 4),
            for (final k in entry.keys)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: glow.withValues(alpha: 0.14),
                  border: Border.all(color: glow.withValues(alpha: 0.35)),
                ),
                child: Text(
                  k,
                  style: TextStyle(fontSize: 11, color: palette.text),
                ),
              ),
            Text(
              !entry.enabled
                  ? 'Switched off'
                  : entry.always
                  ? 'Always on'
                  : 'By key word',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          entry.text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: palette.textMuted,
          ),
        ),
      ],
    );
  }
}

sealed class _EntryResult {}

class _Saved extends _EntryResult {
  _Saved(this.entry);
  final LoreEntry entry;
}

class _Deleted extends _EntryResult {}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.data,
    required this.book,
    required this.index,
    required this.done,
  });

  final VocesData data;
  final Lorebook book;

  /// The entry's place in the book, or null for a new one.
  final int? index;
  final void Function(_EntryResult?) done;

  LoreEntry? get entry => index == null ? null : book.entries[index!];

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  final _title = TextEditingController();
  final _keys = TextEditingController();
  final _text = TextEditingController();
  final _try = TextEditingController();
  var _always = false;
  var _enabled = true;

  late final String _start;
  VocesDraft? _restored;
  var _finished = false;

  VocesLibrary get _library => widget.data.library;
  String get _draftKey => VocesLibrary.draftKey(
    'entry',
    '${widget.book.id}-${widget.index ?? 'new'}',
  );

  @override
  void initState() {
    super.initState();
    _load(widget.entry);
    _start = _fingerprint();
    final draft = _library.draft(_draftKey);
    if (draft != null) {
      _restored = draft;
      _load(LoreEntry.fromJson(draft.item));
    }
  }

  void _load(LoreEntry? e) {
    _title.text = e?.title ?? '';
    _keys.text = e?.keys.join(', ') ?? '';
    _text.text = e?.text ?? '';
    _always = e?.always ?? false;
    _enabled = e?.enabled ?? true;
  }

  LoreEntry _current() {
    final keys = splitTags(_keys.text);
    final title = _title.text.trim();
    return LoreEntry(
      title: title.isNotEmpty
          ? title
          : keys.isNotEmpty
          ? keys.first
          : 'Entry',
      keys: keys,
      text: _text.text.trim(),
      always: _always,
      enabled: _enabled,
    );
  }

  /// Everything the editor would save, to tell whether anything changed.
  String _fingerprint() =>
      [_title.text, _keys.text, _text.text, _always, _enabled].join('\u0001');

  void _keepDraft() => _library.keepDraft(_draftKey, {
    'title': _title.text,
    'keys': splitTags(_keys.text),
    'text': _text.text,
    'always': _always,
    'enabled': _enabled,
  });

  void _dropDraft() {
    setState(() {
      _load(widget.entry);
      _restored = null;
    });
    unawaited(_library.dropDraft(_draftKey));
  }

  Future<void> _cancel() async {
    if (_fingerprint() != _start) {
      final choice = await askLeave(context);
      if (choice == null || !mounted) return;
      if (choice == LeaveChoice.draft) {
        _keepDraft();
      } else {
        await _library.dropDraft(_draftKey);
      }
    } else if (_restored != null) {
      await _library.dropDraft(_draftKey);
    }
    _finished = true;
    widget.done(null);
  }

  Future<void> _finish(_EntryResult result) async {
    _finished = true;
    await _library.dropDraft(_draftKey);
    widget.done(result);
  }

  @override
  void dispose() {
    // Left without Cancel or Save: what was typed waits as a draft.
    if (!_finished && _fingerprint() != _start) _keepDraft();
    for (final c in [_title, _keys, _text, _try]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.palette.textMuted);
    return ListenableBuilder(
      listenable: _text,
      builder: (context, _) => VocesEditorPage(
        title: widget.entry == null
            ? 'New entry in ${widget.book.name}'
            : 'Edit ${widget.entry!.title}',
        saveLabel: 'Save',
        onCancel: _cancel,
        onSave: _text.text.trim().isEmpty
            ? null
            : () => _finish(_Saved(_current())),
        actions: [
          if (widget.entry != null)
            TextButton(
              onPressed: () => _finish(_Deleted()),
              child: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
        banner: _restored == null
            ? null
            : DraftBanner(saved: _restored!.saved, onDrop: _dropDraft),
        preview: _preview(context),
        sections: [
          EditorSection(
            'When it comes in',
            Icons.key_rounded,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _title,
                  autofocus: widget.entry == null && _restored == null,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'The lighthouse',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _keys,
                  decoration: const InputDecoration(
                    labelText: 'Key words',
                    hintText: 'lighthouse, the light, Kael',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'When one of these comes up in the story, the text below '
                  'joins the prompt. Whole words, any case.',
                  style: muted,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _always,
                  onChanged: (v) => setState(() => _always = v),
                  title: const Text('Always on'),
                  subtitle: Text(
                    'For the world\'s tone and rules. Keep these short: they '
                    'take room in every prompt.',
                    style: muted,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                  title: const Text('Switched on'),
                ),
              ],
            ),
          ),
          EditorSection(
            'What it says',
            Icons.notes_rounded,
            TextField(
              controller: _text,
              minLines: 6,
              maxLines: 20,
              decoration: const InputDecoration(
                hintText:
                    'The lighthouse on Gull Rock has burned for three hundred '
                    'years. Nobody living has seen its keeper.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Whether a line would call it up, and what it costs, as it's typed.
  Widget _preview(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_keys, _try]),
    builder: (context, _) {
      final palette = context.palette;
      final e = _current();
      final line = _try.text.trim();
      final lit = line.length >= 3 && LoreMatch.match(line, [e]).isNotEmpty;
      final tokens = (e.text.length / 4).ceil();
      const glow = Color(0xFFFFC88C);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VocesLabel('Try it'),
          const SizedBox(height: 8),
          TextField(
            controller: _try,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'A line from a story',
            ),
          ),
          const SizedBox(height: 10),
          VocesBox(
            highlight: lit ? glow : null,
            child: _EntryTile(entry: e, glow: glow),
          ),
          const SizedBox(height: 8),
          Text(
            !e.enabled
                ? 'Switched off: it never comes in.'
                : e.always
                ? 'Always on: in every prompt.'
                : line.length < 3
                ? 'Type a line to see whether it comes in.'
                : lit
                ? 'This line brings it in.'
                : 'This line leaves it out.',
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            'About $tokens tokens of prompt when it comes in.',
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
        ],
      );
    },
  );
}

Future<String?> _askName(BuildContext context, String title, String name) {
  final c = TextEditingController(text: name);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (c.text.trim().isNotEmpty) Navigator.pop(context, c.text.trim());
          },
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(c.dispose);
}
