import 'package:flutter/material.dart';

import '../../data/voces/voces_library.dart';
import '../../theme/app_theme.dart';

/// The parts of a world update picked to take into a story.
typedef WorldUpdatePick = ({
  bool world,
  Set<String> lorebooks,
  Set<String> cast,
});

/// Shows what changed in a story's world since it began, each part with a
/// tick, and gives back the parts picked (null when cancelled).
Future<WorldUpdatePick?> showWorldUpdate(
  BuildContext context, {
  required String worldName,
  required WorldUpdate update,
}) => showDialog<WorldUpdatePick>(
  context: context,
  builder: (_) => _WorldUpdateDialog(worldName: worldName, update: update),
);

class _WorldUpdateDialog extends StatefulWidget {
  const _WorldUpdateDialog({required this.worldName, required this.update});

  final String worldName;
  final WorldUpdate update;

  @override
  State<_WorldUpdateDialog> createState() => _WorldUpdateDialogState();
}

class _WorldUpdateDialogState extends State<_WorldUpdateDialog> {
  late bool _world = widget.update.world != null;
  // Lorebooks and newcomers are ticked; characters already in the story
  // are not, since the story's copy may have grown while playing.
  late final _books = {for (final b in widget.update.lorebooks) b.book.id};
  late final _cast = {
    for (final c in widget.update.cast)
      if (c.change == WorldChange.added) c.character.id,
  };

  static String _label(WorldChange c) => switch (c) {
    WorldChange.added => 'New',
    WorldChange.changed => 'Changed',
    WorldChange.removed => 'Removed',
  };

  Widget _tick({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String title,
    String? subtitle,
    WorldChange? change,
  }) {
    final palette = context.palette;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: value,
      onChanged: (v) => setState(() => onChanged(v ?? false)),
      title: Row(
        children: [
          if (change != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: palette.tile,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _label(change),
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(title)),
        ],
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: context.palette.textMuted,
        fontSize: 12.5,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final any = _world || _books.isNotEmpty || _cast.isNotEmpty;
    return AlertDialog(
      title: Text('Update from ${widget.worldName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'These changed in the world since this story began. Pick '
                'what the story should use from now on; what has happened '
                'so far stays as it is.',
                style: TextStyle(color: context.palette.textMuted),
              ),
              if (u.world != null) ...[
                _heading('The world'),
                _tick(
                  value: _world,
                  onChanged: (v) => _world = v,
                  title: 'Setting, narrator rules, tags and the rest',
                  subtitle:
                      'Who is in the cast and which lorebooks it '
                      'uses are picked below.',
                ),
              ],
              if (u.lorebooks.isNotEmpty) ...[
                _heading('Lorebooks'),
                for (final (:book, :change) in u.lorebooks)
                  _tick(
                    value: _books.contains(book.id),
                    onChanged: (v) =>
                        v ? _books.add(book.id) : _books.remove(book.id),
                    title: book.name,
                    change: change,
                    subtitle: change == WorldChange.removed
                        ? 'No longer in the world: the story stops using it.'
                        : null,
                  ),
              ],
              if (u.cast.isNotEmpty) ...[
                _heading('Characters'),
                for (final (:character, :change) in u.cast)
                  _tick(
                    value: _cast.contains(character.id),
                    onChanged: (v) => v
                        ? _cast.add(character.id)
                        : _cast.remove(character.id),
                    title: character.name,
                    change: change,
                    subtitle: change == WorldChange.added
                        ? 'Joins the cast; the narrator can bring them in.'
                        : 'Replaces their sheet in this story, including '
                              'anything that changed there while playing.',
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: any
              ? () => Navigator.pop(context, (
                  world: _world,
                  lorebooks: {..._books},
                  cast: {..._cast},
                ))
              : null,
          child: const Text('Update'),
        ),
      ],
    );
  }
}
