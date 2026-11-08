import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../theme/app_theme.dart';

/// Prompts kept as favourites: save the one in the Draw panel under a name,
/// or pick one to load. Gives back the one picked, or null.
Future<DrawPreset?> showDrawPresets(
  BuildContext context, {
  required String prompt,
  String negative = '',
}) => showDialog<DrawPreset>(
  context: context,
  builder: (_) => _PresetsDialog(prompt: prompt, negative: negative),
);

/// Adds a preset (a new name, or replacing the one of the same name).
Future<void> saveDrawPreset(SettingsStore store, DrawPreset preset) {
  final draw = store.value.draw;
  final rest = [
    for (final p in draw.presets)
      if (p.name.toLowerCase() != preset.name.toLowerCase()) p,
  ];
  return store.update(
    store.value.copyWith(draw: draw.copyWith(presets: [preset, ...rest])),
  );
}

/// Asks for a name and keeps [prompt] (and [negative]) as a preset.
/// Gives back whether it was saved.
Future<bool> askSaveDrawPreset(
  BuildContext context, {
  required String prompt,
  String negative = '',
}) async {
  final store = AppScope.of(context).settings;
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(prompt: prompt),
  );
  if (name == null || name.trim().isEmpty) return false;
  await saveDrawPreset(
    store,
    DrawPreset(name: name.trim(), prompt: prompt.trim(), negative: negative),
  );
  return true;
}

/// A name for a preset made from [prompt]: its first few words.
String presetNameFor(String prompt) {
  final words = prompt
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .split(' ')
      .take(5)
      .join(' ');
  return words.length > 40 ? '${words.substring(0, 39)}…' : words;
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.prompt});

  final String prompt;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: presetNameFor(widget.prompt));

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save as a preset'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 10),
          Text(
            widget.prompt,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: context.palette.textMuted),
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
        onPressed: () => Navigator.pop(context, _name.text),
        child: const Text('Save'),
      ),
    ],
  );
}

class _PresetsDialog extends StatelessWidget {
  const _PresetsDialog({required this.prompt, required this.negative});

  final String prompt;
  final String negative;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).settings;
    final palette = context.palette;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final presets = store.value.draw.presets;
        return AlertDialog(
          title: const Text('Prompt presets'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: prompt.trim().isEmpty
                      ? null
                      : () => askSaveDrawPreset(
                          context,
                          prompt: prompt,
                          negative: negative,
                        ),
                  icon: const Icon(Icons.star_outline_rounded, size: 18),
                  label: const Text('Save the prompt you have now'),
                ),
                const SizedBox(height: 12),
                if (presets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No presets yet. Save a prompt you like, then load it '
                      'here any time.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.textMuted),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final p in presets)
                          ListTile(
                            contentPadding: const EdgeInsets.only(left: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            title: Text(p.name),
                            subtitle: Text(
                              p.prompt,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.textMuted,
                              ),
                            ),
                            onTap: () => Navigator.pop(context, p),
                            trailing: IconButton(
                              tooltip: 'Remove this preset',
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 20,
                              ),
                              onPressed: () {
                                final draw = store.value.draw;
                                store.update(
                                  store.value.copyWith(
                                    draw: draw.copyWith(
                                      presets: [
                                        for (final q in draw.presets)
                                          if (q != p) q,
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
