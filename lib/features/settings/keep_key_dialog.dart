import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../theme/app_theme.dart';
import 'encryption_settings.dart';

/// Asks the human to keep a copy of the key their chats and memories are
/// encrypted with, or to pick their own password, before going on. Shown
/// once after the update that turned encryption on (after What's new),
/// after setup on a new install, and whenever a new random key replaces
/// the old one.
Future<void> showKeepKey(BuildContext context) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => const KeepKeyDialog(),
);

class KeepKeyDialog extends StatefulWidget {
  const KeepKeyDialog({super.key});

  @override
  State<KeepKeyDialog> createState() => _KeepKeyDialogState();
}

class _KeepKeyDialogState extends State<KeepKeyDialog> {
  bool _shown = false;
  bool _busy = false;

  /// What the human did to keep it; Continue waits for one of them.
  String? _kept;

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: AppScope.of(context).dbKey.value),
    );
    setState(
      () => _kept =
          'Copied. Paste it into a password manager or somewhere else safe.',
    );
  }

  Future<void> _ownPassword() async {
    final services = AppScope.of(context);
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const OwnPasswordDialog(),
    );
    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await services.changeDatabaseKey(password);
      if (!mounted) return;
      setState(() {
        _shown = false;
        _kept = 'Your password is now the key. Keep it somewhere safe.';
      });
    } on Object catch (e) {
      if (mounted) setState(() => _kept = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("The key couldn't be changed: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    await AppScope.of(context).dbKey.markSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final key = AppScope.of(context).dbKey.value;
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: Icon(Icons.lock_rounded, color: accent),
        title: const Text('Keep a copy of your key'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your chats and memories are encrypted on this computer. '
                'VoxCordis remembers the key here, so it opens without '
                'asking.\n\n'
                'On a new computer, or if your keyring is reset, it asks for '
                "the key. Without it your chats and memories can't be "
                'opened, by you or anyone else.',
                style: TextStyle(color: palette.textMuted, height: 1.4),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: palette.codeFill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        _shown ? key : '•' * 32,
                        maxLines: 2,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _shown ? 'Hide the key' : 'Show the key',
                    icon: Icon(
                      _shown
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                    onPressed: () => setState(() => _shown = !_shown),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _copy,
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy the key'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _ownPassword,
                    icon: const Icon(Icons.password_rounded),
                    label: const Text('Use my own password instead'),
                  ),
                  if (_busy)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              if (_kept != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.check_circle_rounded, size: 18, color: accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _kept!,
                        style: TextStyle(fontSize: 13, color: palette.text),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'You can see it again any time in Settings → Privacy.',
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _kept == null || _busy ? null : _continue,
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}
