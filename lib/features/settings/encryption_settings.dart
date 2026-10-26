import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../data/database_key.dart';
import '../../services/secret_store.dart';
import '../../theme/app_theme.dart';
import 'keep_key_dialog.dart';

/// Settings → Privacy: the key the chats and memories are encrypted with.
/// Show and copy it (needed on a new computer), swap it for a new random
/// one, or use a password of one's own.
class EncryptionSettings extends StatefulWidget {
  const EncryptionSettings({super.key});

  @override
  State<EncryptionSettings> createState() => _EncryptionSettingsState();
}

class _EncryptionSettingsState extends State<EncryptionSettings> {
  bool _shown = false;
  bool _busy = false;
  SecretPlace? _place;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_place == null) _findPlace();
  }

  Future<void> _findPlace() async {
    final key = AppScope.of(context).dbKey;
    final place = await key.secrets.placeOf(DatabaseKey.secretName);
    if (mounted) setState(() => _place = place);
  }

  Future<void> _copy(String key) async {
    final dbKey = AppScope.of(context).dbKey;
    await Clipboard.setData(ClipboardData(text: key));
    await dbKey.markSaved();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Key copied. Keep it somewhere safe, such as a password '
          'manager.',
        ),
      ),
    );
  }

  /// True when [next] is the key now.
  Future<bool> _change(String next, String done) async {
    setState(() => _busy = true);
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await services.changeDatabaseKey(next);
      messenger.showSnackBar(SnackBar(content: Text(done)));
      return true;
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("The key couldn't be changed: $e")),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _findPlace();
      }
    }
  }

  Future<void> _newRandom() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Make a new key?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Your chats and memories are encrypted again with a new random '
            'key. The old key stops working, so replace any copy you kept.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('New key'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final services = AppScope.of(context);
    if (!await _change(DatabaseKey.generate(), 'New key in use.')) return;
    // The old copy is no use now: keep the new one before going on.
    await services.dbKey.markUnsaved();
    if (mounted) await showKeepKey(context);
  }

  Future<void> _ownPassword() async {
    final password = await showDialog<String>(
      context: context,
      builder: (context) => const OwnPasswordDialog(),
    );
    if (password == null || !mounted) return;
    final services = AppScope.of(context);
    if (await _change(password, 'Your password is now the key.')) {
      await services.dbKey.markSaved();
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final key = services.dbKey.value;
    final name = services.settings.value.companionName;
    final palette = context.palette;
    final muted = TextStyle(
      fontSize: 12,
      color: palette.textMuted,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        Text(
          'Your chats and memories are encrypted on this computer. '
          '${switch (_place) {
            SecretPlace.keyring => 'The key is kept in your desktop keyring, so VoxCordis opens without asking.',
            SecretPlace.windows => 'The key is kept encrypted for your Windows account, so VoxCordis opens without asking.',
            SecretPlace.file => "No keyring was available, so the key is kept in a file only your account can open. That keeps out other accounts on this computer, but not someone who copies the whole app folder. With GNOME Keyring or KWallet running, a new key goes there instead.",
            null => '',
          }}',
          style: muted,
        ),
        const SizedBox(height: 14),
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
            const SizedBox(width: 6),
            IconButton(
              tooltip: _shown ? 'Hide the key' : 'Show the key',
              icon: Icon(
                _shown
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
              onPressed: () => setState(() => _shown = !_shown),
            ),
            IconButton(
              tooltip: 'Copy the key',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => _copy(key),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Keep a copy somewhere safe, such as a password manager. On a new '
          'computer, or if the keyring is reset, VoxCordis asks for it. '
          "Without it your chats and memories can't be opened.",
          style: muted.copyWith(color: palette.text),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _newRandom,
              icon: const Icon(Icons.autorenew_rounded),
              label: const Text('New random key'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _ownPassword,
              icon: const Icon(Icons.password_rounded),
              label: const Text('Use my own password'),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          "$name's folder (personality, notes, pictures) is not encrypted, "
          'so you and $name can open those files directly.',
          style: muted,
        ),
      ],
    );
  }
}

/// Asks for a password twice; returns it, or null when cancelled.
class OwnPasswordDialog extends StatefulWidget {
  const OwnPasswordDialog({super.key});

  @override
  State<OwnPasswordDialog> createState() => _OwnPasswordDialogState();
}

class _OwnPasswordDialogState extends State<OwnPasswordDialog> {
  final _one = TextEditingController();
  final _two = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _one.dispose();
    _two.dispose();
    super.dispose();
  }

  void _submit() {
    final pw = _one.text;
    if (pw.trim().length < DatabaseKey.minPasswordLength) {
      setState(
        () => _problem =
            'Use at least ${DatabaseKey.minPasswordLength} characters.',
      );
    } else if (pw != _two.text) {
      setState(() => _problem = "The two don't match.");
    } else if (pw != pw.trim()) {
      setState(() => _problem = 'Leave out spaces at the start and end.');
    } else {
      Navigator.pop(context, pw);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Use your own password'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'It becomes the key to your chats and memories. A long '
            'passphrase is best. VoxCordis still remembers it on this '
            'computer and only asks on another one.',
            style: TextStyle(
              fontSize: 12,
              color: context.palette.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _one,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _two,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Once more',
              errorText: _problem,
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
      FilledButton(onPressed: _submit, child: const Text('Use it')),
    ],
  );
}
