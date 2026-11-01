import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/import/soulkyn_browser.dart';
import '../../services/import/soulkyn_gallery.dart';
import '../../services/import/soulkyn_link.dart';
import '../../services/import/soulkyn_media.dart';
import '../../theme/app_theme.dart';

/// Asks for a Kyn's link and saves every picture and video in its Soulkyn
/// gallery into [into], the companion's `images/` unless setup passes a
/// folder of its own. With [folder] the link is remembered for the next
/// press; with [link] it is filled in, and [start] begins at once. True
/// when anything new came in.
Future<bool> showSoulkynDownload(
  BuildContext context, {
  required Directory into,
  String? folder,
  Uri? link,
  bool start = false,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SoulkynDownloadDialog(
        into: into,
        folder: folder,
        link: link,
        start: start,
      ),
    ) ??
    false;

/// The last link used for this companion, so the next press only needs
/// "Download".
File _linkFile(String folder) =>
    File(p.join(folder, 'imported', 'soulkyn-link.txt'));

/// Remembers [page] as the companion's Soulkyn link.
Future<void> rememberSoulkynLink(String folder, Uri page) async {
  try {
    await _linkFile(folder).parent.create(recursive: true);
    await _linkFile(folder).writeAsString('$page\n');
  } on FileSystemException {
    // Only a convenience.
  }
}

enum _Stage { ask, reading, saving, done }

class _SoulkynDownloadDialog extends StatefulWidget {
  const _SoulkynDownloadDialog({
    required this.into,
    this.folder,
    this.link,
    this.start = false,
  });
  final Directory into;
  final String? folder;
  final Uri? link;
  final bool start;

  @override
  State<_SoulkynDownloadDialog> createState() => _SoulkynDownloadDialogState();
}

class _SoulkynDownloadDialogState extends State<_SoulkynDownloadDialog> {
  final _link = TextEditingController();

  /// The link from Soulkyn's login email, which would otherwise log in
  /// the human's own browser instead of the window.
  final _signIn = TextEditingController();
  _Stage _stage = _Stage.ask;
  bool _nsfw = true;
  String? _error;
  SoulkynGallery? _gallery;
  SoulkynMediaDownload? _download;
  SoulkynMediaProgress? _progress;
  int _leftOut = 0;
  bool _loggedOut = false;

  @override
  void initState() {
    super.initState();
    final folder = widget.folder;
    if (widget.link != null) {
      _link.text = '${widget.link}';
    } else if (folder != null && _linkFile(folder).existsSync()) {
      final f = _linkFile(folder);
      try {
        _link.text = f.readAsStringSync().trim();
      } on FileSystemException {
        // Start empty.
      }
    }
    if (widget.start && _link.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  @override
  void dispose() {
    _link.dispose();
    _signIn.dispose();
    unawaited(_gallery?.close());
    _download?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final page = SoulkynLink.parse(_link.text);
    if (page == null) {
      setState(
        () => _error =
            'Paste the Kyn\'s page link, like https://soulkyn.com/@name.',
      );
      return;
    }
    final gallery = _gallery = SoulkynGallery();
    setState(() {
      _error = null;
      _stage = _Stage.reading;
    });
    List<SoulkynMedia> all;
    try {
      all = await gallery.read(page);
    } on SoulkynLinkFailed catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _stage = _Stage.ask;
        });
      }
      return;
    } finally {
      _gallery = null;
    }
    if (!mounted) return;
    final folder = widget.folder;
    if (folder != null) await rememberSoulkynLink(folder, page);
    final items = _nsfw ? all : all.where((m) => !m.nsfw).toList();
    final download = _download = SoulkynMediaDownload();
    setState(() {
      _leftOut = all.length - items.length;
      _stage = _Stage.saving;
      _progress = SoulkynMediaProgress(total: items.length);
    });
    try {
      final done = await download.saveAll(
        items,
        widget.into,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) {
        setState(() {
          _progress = done;
          _stage = _Stage.done;
        });
      }
    } finally {
      download.close();
      _download = null;
    }
  }

  void _cancel() {
    unawaited(_gallery?.close());
    _download?.cancel();
    Navigator.pop(context, (_progress?.saved ?? 0) > 0);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final muted = TextStyle(fontSize: 12.5, color: palette.textMuted);
    final progress = _progress;
    final Widget body = switch (_stage) {
      _Stage.ask => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Saves every picture and video in the Kyn\'s Soulkyn gallery '
            'into Pictures. Pressing it again later only fetches new ones.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _link,
            autofocus: _link.text.isEmpty,
            decoration: InputDecoration(
              labelText: 'Kyn link',
              hintText: 'https://soulkyn.com/@name',
              errorText: _error,
              errorMaxLines: 4,
            ),
            onSubmitted: (_) => _start(),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: _nsfw,
            onChanged: (v) => setState(() => _nsfw = v ?? true),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Include NSFW pictures and videos'),
          ),
          Text(
            'A Soulkyn window opens and goes through the Gallery and Videos '
            'tabs. If Soulkyn asks you to log in or check you\'re human, do '
            'it there. The login is kept for next time.',
            style: muted,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _loggedOut
                  ? null
                  : () async {
                      await SoulkynBrowser.logOut();
                      if (mounted) setState(() => _loggedOut = true);
                    },
              child: Text(
                _loggedOut ? 'Logged out of Soulkyn' : 'Log out of Soulkyn',
              ),
            ),
          ),
        ],
      ),
      _Stage.reading => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: _gallery?.status ?? ValueNotifier(''),
            builder: (_, s, _) => Text(s),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _signIn,
            decoration: const InputDecoration(
              labelText: 'Sign-in link from Soulkyn\'s email (optional)',
              isDense: true,
            ),
            onSubmitted: (text) async {
              if (await _gallery?.openLink(text) ?? false) _signIn.clear();
            },
          ),
        ],
      ),
      _Stage.saving || _Stage.done => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: progress == null || progress.total == 0
                ? (_stage == _Stage.done ? 1 : null)
                : progress.done / progress.total,
          ),
          const SizedBox(height: 12),
          Text(_summary(progress)),
          if (_leftOut > 0) ...[
            const SizedBox(height: 6),
            Text(
              '$_leftOut NSFW ${_leftOut == 1 ? 'file was' : 'files were'} '
              'left out.',
              style: muted,
            ),
          ],
        ],
      ),
    };
    return AlertDialog(
      title: const Text('Download from Soulkyn'),
      content: SizedBox(width: 440, child: body),
      actions: [
        if (_stage == _Stage.done)
          FilledButton(
            onPressed: () => Navigator.pop(context, (progress?.saved ?? 0) > 0),
            child: const Text('Done'),
          )
        else ...[
          TextButton(onPressed: _cancel, child: const Text('Cancel')),
          if (_stage == _Stage.ask)
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download all'),
            ),
        ],
      ],
    );
  }

  String _summary(SoulkynMediaProgress? p) {
    if (p == null) return '';
    if (p.total == 0) return 'The gallery is empty.';
    final parts = [
      if (p.saved > 0) '${p.saved} new',
      if (p.skipped > 0) '${p.skipped} already saved',
      if (p.failed > 0) '${p.failed} failed',
    ];
    final head = _stage == _Stage.done
        ? 'Done: ${p.total} ${p.total == 1 ? 'file' : 'files'}'
        : 'Saving ${p.done} of ${p.total}';
    return parts.isEmpty ? head : '$head (${parts.join(', ')}).';
  }
}
