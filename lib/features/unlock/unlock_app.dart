import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/database_key.dart';
import '../../shell/window_frame.dart';
import '../../theme/app_theme.dart';

/// Shown instead of the app when the chats and memories are encrypted but
/// this computer doesn't have their key: a new computer, or a keyring that
/// was reset. Settings → Privacy shows the key to keep for this.
class UnlockApp extends StatelessWidget {
  const UnlockApp({super.key, required this.dbKey, required this.onUnlocked});

  final DatabaseKey dbKey;

  /// Starts the real app.
  final VoidCallback onUnlocked;

  static const _accent = Color(0xFFB18CFF);

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'VoxCordis',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(_accent),
    color: Colors.transparent,
    builder: (context, navigator) => WindowCorners(
      child: AuroraBackground(
        accent: _accent,
        child: WindowFrame(child: navigator!),
      ),
    ),
    home: UnlockScreen(dbKey: dbKey, onUnlocked: onUnlocked),
  );
}

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({
    super.key,
    required this.dbKey,
    required this.onUnlocked,
  });

  final DatabaseKey dbKey;
  final VoidCallback onUnlocked;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _field = TextEditingController();
  bool _hidden = true;
  bool _busy = false;
  String? _problem;
  Timer? _again;
  int _tries = 0;

  /// How often, and how many times, the stored key is looked for again
  /// by itself: at login the keyring may not be unlocked or running yet.
  static const retryEvery = Duration(seconds: 5);
  static const retries = 36;

  @override
  void initState() {
    super.initState();
    _again = Timer.periodic(retryEvery, (t) {
      if (++_tries >= retries) t.cancel();
      _tryStored(quiet: true);
    });
  }

  @override
  void dispose() {
    _again?.cancel();
    _field.dispose();
    super.dispose();
  }

  /// Looks for the stored key again (the keyring may have unlocked).
  Future<void> _tryStored({bool quiet = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      if (!quiet) _problem = null;
    });
    final ok = await widget.dbKey.unlock();
    if (!mounted) return;
    if (ok) {
      _again?.cancel();
      return widget.onUnlocked();
    }
    setState(() {
      _busy = false;
      if (!quiet) {
        _problem =
            'The key still isn\'t there. Is your keyring (GNOME Keyring, '
            'KWallet) unlocked?';
      }
    });
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final ok = await widget.dbKey.tryPassword(_field.text.trim());
    if (!mounted) return;
    if (ok) {
      _again?.cancel();
      return widget.onUnlocked();
    }
    setState(() {
      _busy = false;
      _problem = "That isn't the key. Check for typos, or paste it again.";
    });
  }

  Future<void> _startOver() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start over without the key?'),
        content: const Text(
          'Your chats and memories stay encrypted and are moved into a '
          '"locked" folder in the app data. VoxCordis starts again with '
          'empty chats and memories, and keeps any key it had. When the '
          'key turns up, Settings → Privacy brings them back. Your '
          "companions' folders (personality, notes, pictures) are not "
          'affected.\n\n'
          'If your keyring is only locked, unlock it and choose Try again '
          'instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start over'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    await widget.dbKey.setAside();
    widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassPanel(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.lock_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Unlock your chats',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your chats and memories are encrypted, and this '
                    "computer can't find their key. That happens on a new "
                    'computer, when the keyring was reset, or while the '
                    'keyring is still locked after logging in. Unlock it '
                    'and this screen goes away by itself.\n\n'
                    'Or enter the key you copied from Settings → Privacy, '
                    'or your own password if you set one.',
                    style: muted,
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _field,
                    autofocus: true,
                    obscureText: _hidden,
                    enabled: !_busy,
                    onSubmitted: (_) => _unlock(),
                    decoration: InputDecoration(
                      labelText: 'Key or password',
                      errorText: _problem,
                      errorMaxLines: 2,
                      suffixIcon: IconButton(
                        tooltip: _hidden ? 'Show' : 'Hide',
                        icon: Icon(
                          _hidden
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                        onPressed: () => setState(() => _hidden = !_hidden),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : _startOver,
                        child: const Text('I lost the key'),
                      ),
                      TextButton.icon(
                        onPressed: _busy ? null : _tryStored,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _unlock,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_open_rounded),
                        label: const Text('Unlock'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
