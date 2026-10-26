import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/database_key.dart';
import '../../services/export/companion_export.dart';
import '../../theme/app_theme.dart';

/// Exports the current companion to a ZIP ([CompanionExport]): what goes
/// in, and a password, which is on by default because the ZIP leaves the
/// encrypted database behind.
Future<void> showExportDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const ExportDialog());

class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key, this.pickTarget});

  /// Where to save; the system's save dialog unless a test replaces it.
  final Future<File?> Function(String suggestedName)? pickTarget;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _chat = true;
  bool _files = true;
  bool _lock = true;
  bool _hidden = true;
  bool _busy = false;
  String? _error;
  String? _passwordError;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<File?> _pick(String name) async {
    final at = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ZIP', extensions: ['zip']),
      ],
    );
    if (at == null) return null;
    final path = at.path.toLowerCase().endsWith('.zip')
        ? at.path
        : '${at.path}.zip';
    return File(path);
  }

  Future<void> _export() async {
    final services = AppScope.of(context);
    final s = services.settings.value;
    if (_lock) {
      final pw = _password.text;
      final problem = pw.length < DatabaseKey.minPasswordLength
          ? 'Use at least ${DatabaseKey.minPasswordLength} characters.'
          : pw != _repeat.text
          ? 'The two passwords differ.'
          : null;
      setState(() => _passwordError = problem);
      if (problem != null) return;
    }
    final name = CompanionExport.suggestedName(s.companionName, DateTime.now());
    final out = await (widget.pickTarget ?? _pick)(name);
    if (out == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await CompanionExport.write(
        settings: s,
        db: services.db,
        out: out,
        password: _lock ? _password.text : null,
        chat: _chat,
        files: _files,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      final big = done.skipped.isEmpty
          ? ''
          : ' ${done.skipped.length} file(s) over 64 MB stayed behind.';
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            '${s.companionName} is saved to ${out.path}: '
            '${done.memories} memories, ${done.messages} messages, '
            '${done.files} files.$big',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The export did not work: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final name = AppScope.of(context).settings.value.companionName;
    final muted = TextStyle(color: palette.textMuted, height: 1.4);
    return AlertDialog(
      title: Text('Export $name'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'One ZIP with $name\'s personality, lessons, privacy rules, '
                'memories and plans. To bring it back, here or on another '
                'computer, use Import a character when adding a companion. '
                'Settings, '
                'API keys and your database key never go in.',
                style: muted,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _chat,
                onChanged: _busy ? null : (v) => setState(() => _chat = v!),
                title: const Text('Chat history'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _files,
                onChanged: _busy ? null : (v) => setState(() => _files = v!),
                title: Text('Files in $name\'s folder'),
                subtitle: Text(
                  'Portrait, pictures and notes. Files over 64 MB stay '
                  'behind.',
                  style: muted.copyWith(fontSize: 12),
                ),
              ),
              const Divider(height: 20),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _lock,
                onChanged: _busy ? null : (v) => setState(() => _lock = v),
                title: const Text('Lock it with a password'),
                subtitle: Text(
                  _lock
                      ? 'Every file inside is AES-256 encrypted. File names '
                            'stay readable. Lose the password and nobody can '
                            'open it, VoxCordis included.'
                      : 'Without a password the ZIP is not encrypted: '
                            'anyone who gets the file can read every chat '
                            'and memory in it.',
                  style: muted.copyWith(
                    fontSize: 12,
                    color: _lock ? null : Colors.orangeAccent,
                  ),
                ),
              ),
              if (_lock) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _hidden,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    errorText: _passwordError,
                    suffixIcon: IconButton(
                      tooltip: _hidden ? 'Show' : 'Hide',
                      icon: Icon(
                        _hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _repeat,
                  enabled: !_busy,
                  obscureText: _hidden,
                  onSubmitted: (_) => _export(),
                  decoration: const InputDecoration(
                    labelText: 'Password again',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.ios_share_rounded, size: 18),
          label: Text(_busy ? 'Exporting…' : 'Export…'),
        ),
      ],
    );
  }
}
