import 'package:flutter/material.dart';

import '../../app_scope.dart';

/// The sentence the human types to confirm deleting [name].
String deletePhrase(String name) => 'Yes, I want to delete $name!';

/// Whether [typed] confirms deleting [name]: exactly the phrase, case
/// included.
bool deleteConfirmed(String typed, String name) => typed == deletePhrase(name);

/// The sentence the human types to confirm resetting [name].
String resetPhrase(String name) => 'Yes, I want to reset $name!';

/// Whether [typed] confirms resetting [name], exactly.
bool resetConfirmed(String typed, String name) => typed == resetPhrase(name);

/// Asks once, with a typed sentence, before wiping the current companion's
/// chats, memories and reminders. They and their folder stay.
Future<void> confirmResetCompanion(BuildContext context) async {
  final services = AppScope.of(context);
  final name = services.settings.value.companionName;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _ResetDialog(name: name),
  );
  if (ok != true) return;
  await services.resetCurrentCompanion();
}

class _ResetDialog extends StatefulWidget {
  const _ResetDialog({required this.name});
  final String name;

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    return AlertDialog(
      title: Text('Reset $name?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$name forgets every chat, memory and reminder, as if you had '
              'just met. Who $name is stays: name, personality and folder. '
              'There is no undo.',
            ),
            const SizedBox(height: 12),
            Text('To confirm, type:\n${resetPhrase(name)}'),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: resetConfirmed(_text.text, name)
              ? () => Navigator.pop(context, true)
              : null,
          child: Text('Reset $name'),
        ),
      ],
    );
  }
}

/// Asks twice before deleting the current companion: first a warning of
/// what goes, then the human types a sentence. Deletes it when both pass.
Future<void> confirmDeleteCompanion(BuildContext context) async {
  final services = AppScope.of(context);
  final name = services.settings.value.companionName;
  final first = await showDialog<bool>(
    context: context,
    builder: (_) => _Warning(name: name),
  );
  if (first != true || !context.mounted) return;
  final second = await showDialog<bool?>(
    context: context,
    builder: (_) => _TypeToConfirm(name: name),
  );
  if (second == null || !context.mounted) return;
  await services.deleteCurrentCompanion(deleteFolder: second);
}

class _Warning extends StatelessWidget {
  const _Warning({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Delete $name?'),
    content: Text(
      'This removes $name for good: every chat and every memory. There is '
      'no undo, so export $name first if you might want them back.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text('Keep $name'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Continue'),
      ),
    ],
  );
}

/// Pops with whether to delete the folder too, or null when cancelled.
class _TypeToConfirm extends StatefulWidget {
  const _TypeToConfirm({required this.name});
  final String name;

  @override
  State<_TypeToConfirm> createState() => _TypeToConfirmState();
}

class _TypeToConfirmState extends State<_TypeToConfirm> {
  final _text = TextEditingController();
  bool _folder = true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return AlertDialog(
      title: Text('Really delete ${widget.name}?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To confirm, type:\n${deletePhrase(widget.name)}'),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _folder,
              onChanged: (v) => setState(() => _folder = v ?? true),
              title: Text(
                'Also delete ${widget.name}\'s folder (personality, notes '
                'and pictures)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: deleteConfirmed(_text.text, widget.name)
              ? () => Navigator.pop(context, _folder)
              : null,
          child: Text('Delete ${widget.name}'),
        ),
      ],
    );
  }
}
