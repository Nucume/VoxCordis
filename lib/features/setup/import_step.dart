import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/desk/desk_files.dart';
import '../../services/import/avatar_download.dart';
import '../../services/import/character_card.dart';
import '../../services/import/imported_character.dart';
import '../../services/import/nemini_import.dart';
import '../../services/import/soulkyn_browser.dart';
import '../../services/import/soulkyn_link.dart';
import '../../services/import/untrusted_text.dart';
import '../../services/system/system_tools.dart';
import '../../theme/app_theme.dart';

enum ImportSource {
  nemini(
    'Nemini',
    'The export ZIP from Nemini.ai: personality, lessons, memories, chat '
        'and desk files. API keys and account links are never read.',
    Icons.folder_zip_outlined,
    XTypeGroup(label: 'Nemini export', extensions: ['zip']),
  ),
  soulkyn(
    'Soulkyn',
    'Paste the link to a character\'s page, or use the exporter '
        'bookmarklet\'s .json.',
    Icons.auto_awesome_outlined,
    XTypeGroup(label: 'Soulkyn export', extensions: ['json']),
  ),
  card(
    'Character card',
    'A .png or .json card from SillyTavern, chub, Character.AI exporters and '
        'most other apps (Character Card V1, V2 and V3).',
    Icons.badge_outlined,
    XTypeGroup(label: 'Character card', extensions: ['png', 'json']),
  );

  const ImportSource(this.label, this.description, this.icon, this.types);

  final String label;
  final String description;
  final IconData icon;
  final XTypeGroup types;

  /// Reads [file]. Cards and Soulkyn files are told apart by what is in
  /// them, so picking the wrong one of those two still works.
  Future<ImportedCharacter> read(File file) => switch (this) {
    nemini => NeminiExport.read(file),
    _ => CharacterCard.read(file),
  };
}

/// The choice of where a character comes from; picking one opens a file.
class ImportSources extends StatefulWidget {
  const ImportSources({
    super.key,
    required this.onImported,
    this.pick,
    this.fetchSoulkyn,
  });

  final ValueChanged<ImportedCharacter> onImported;

  /// Picks the file; the system's open dialog unless a test replaces it.
  final Future<File?> Function(ImportSource source)? pick;

  /// Reads a Soulkyn link; [SoulkynLink.fetch] unless a test replaces it.
  final Future<ImportedCharacter> Function(Uri url)? fetchSoulkyn;

  @override
  State<ImportSources> createState() => _ImportSourcesState();
}

class _ImportSourcesState extends State<ImportSources> {
  ImportSource? _busy;
  String? _error;

  Future<File?> _open(ImportSource source) async {
    final f = await openFile(acceptedTypeGroups: [source.types]);
    return f == null ? null : File(f.path);
  }

  Future<void> _choose(ImportSource source) async {
    final pick = widget.pick ?? _open;
    if (source == ImportSource.soulkyn) {
      final got = await showDialog<Object>(
        context: context,
        builder: (_) => SoulkynImportDialog(
          pickFile: () => pick(source),
          fetch: widget.fetchSoulkyn,
        ),
      );
      if (!mounted || got == null) return;
      if (got is ImportedCharacter) return widget.onImported(got);
      if (got is File) return _read(source, got);
      return;
    }
    final file = await pick(source);
    if (file == null || !mounted) return;
    await _read(source, file);
  }

  Future<void> _read(ImportSource source, File file) async {
    setState(() {
      _busy = source;
      _error = null;
    });
    try {
      final character = await source.read(file);
      if (mounted) widget.onImported(character);
    } on ImportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'That file could not be read: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Bring a character you already know. You can read and change '
          'everything before it moves in.',
          style: TextStyle(color: context.palette.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        for (final s in ImportSource.values) ...[
          Material(
            color: context.palette.tile,
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              leading: Icon(s.icon),
              title: Text(s.label),
              subtitle: Text(
                s.description,
                style: TextStyle(
                  fontSize: 12,
                  color: context.palette.textMuted,
                ),
              ),
              trailing: _busy == s
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded),
              enabled: _busy == null,
              onTap: () => _choose(s),
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
      ],
    );
  }
}

/// The step after Personality for an imported character: the prose that
/// becomes personality.md, its looks, anything worth a second look and,
/// for Nemini, what else to bring. The linked picture is offered on the
/// character step ([PortraitDownload]).
class ImportReview extends StatefulWidget {
  const ImportReview({
    super.key,
    required this.character,
    required this.name,
    required this.body,
    required this.looks,
  });

  final ImportedCharacter character;
  final String name;
  final TextEditingController body;
  final Map<String, TextEditingController> looks;

  /// The body may never pass the largest personality.md allows.
  static int get maxBody => DeskFiles.personalityMaxChars(1 << 20) - 1500;

  @override
  State<ImportReview> createState() => _ImportReviewState();
}

class _ImportReviewState extends State<ImportReview> {
  /// Checked again as the human edits, so a fixed line drops off.
  List<TextFlag> get _flags => [
    ...UntrustedText.flags(widget.body.text),
    if (widget.character.lessons != null)
      ...UntrustedText.flags(widget.character.lessons!),
    for (final l in widget.looks.values) ...UntrustedText.flags(l.text),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.body, ...widget.looks.values]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final c = widget.character;
    final flags = _flags;
    final nemini = c.nemini;
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);
    final small = TextStyle(fontSize: 12, color: context.palette.textMuted);
    const header = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'This came from ${c.source}. It becomes the start of '
          '${widget.name}\'s personality file, which is part of every prompt, '
          'so read it through. Text written elsewhere can hide instructions '
          'meant for the AI; change or delete anything you don\'t want.',
          style: muted,
        ),
        if (flags.isNotEmpty) ...[
          const SizedBox(height: 14),
          _Box(
            color: Colors.orangeAccent,
            icon: Icons.warning_amber_rounded,
            children: [
              const Text('Worth a second look', style: header),
              const SizedBox(height: 6),
              for (final f in flags.take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('“${f.excerpt}” (${f.reason})', style: small),
                ),
              if (flags.length > 8)
                Text('and ${flags.length - 8} more', style: small),
            ],
          ),
        ],
        if (c.notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final n in c.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: context.palette.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(n, style: small)),
                ],
              ),
            ),
        ],
        if (nemini == null)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: c.rewrite,
            onChanged: (v) => setState(() => c.rewrite = v!),
            title: Text('Ask ${widget.name} to rewrite this after setup'),
            subtitle: Text(
              'Once settled in, ${widget.name} turns it from a roleplay card '
              'into a personality in their own words: game stats, scenario '
              'set-ups and instructions to the AI go, the character stays. '
              'Leave it off to keep the text as it is.',
            ),
          ),
        if (nemini != null) ...[
          const SizedBox(height: 14),
          const Text('Also bring', style: header),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: nemini.memories,
            onChanged: nemini.factCount == 0
                ? null
                : (v) => setState(() => nemini.memories = v!),
            title: Text('${nemini.factCount} memories'),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: nemini.chat,
            onChanged: nemini.messageCount == 0
                ? null
                : (v) => setState(() => nemini.chat = v!),
            title: Text('About ${nemini.messageCount} chat messages'),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: nemini.desk,
            onChanged: nemini.deskFiles.isEmpty
                ? null
                : (v) => setState(() => nemini.desk = v!),
            title: Text('${nemini.deskFiles.length} desk files'),
            subtitle: Text(
              'Copied into the companion folder; files already there are '
              'kept.',
              style: small,
            ),
          ),
          if (nemini.taskCount > 0)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: nemini.tasks,
              onChanged: (v) => setState(() => nemini.tasks = v!),
              title: Text('${nemini.taskCount} reminders and automations'),
              subtitle: Text(
                'They arrive paused: check each one in the Plans tab and '
                'resume the ones you want.',
                style: small,
              ),
            ),
          if (nemini.otherFiles.isNotEmpty) _OtherDeskFiles(nemini),
          if (c.lessons != null)
            Text(
              'lessons.md and privacy.md come over as they are.',
              style: small,
            ),
        ],
        const SizedBox(height: 14),
        const Text('Looks', style: header),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final k in DeskFiles.looksKeys)
              SizedBox(
                width: 220,
                child: TextField(
                  controller: widget.looks[k],
                  decoration: InputDecoration(labelText: k, isDense: true),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('Personality', style: header)),
            ListenableBuilder(
              listenable: widget.body,
              builder: (context, _) {
                final n = widget.body.text.length;
                final over = n > ImportReview.maxBody;
                return Text(
                  '$n / ${ImportReview.maxBody}',
                  style: small.copyWith(color: over ? Colors.redAccent : null),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: widget.body,
          minLines: 12,
          maxLines: null,
          style: const TextStyle(fontSize: 13, height: 1.45),
          decoration: const InputDecoration(
            alignLabelWithHint: true,
            hintText: 'Who your companion is, in prose, under # headings.',
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'A short memory span allows a shorter file (6000 characters at 4k). '
          'If this is longer, your companion has to tighten it the first time '
          'it edits the file.',
          style: small,
        ),
      ],
    );
  }
}

/// Soulkyn: a pasted link first. When the app can't read the page
/// directly (usually a Cloudflare check), it opens the page in a browser
/// window, where the human can pass the check, and reads it there. Without
/// a browser, or when the user prefers, the exporter bookmarklet with steps
/// and a Copy button; its file is then picked here. Pops an
/// [ImportedCharacter] or the picked [File].
class SoulkynImportDialog extends StatefulWidget {
  const SoulkynImportDialog({
    super.key,
    required this.pickFile,
    this.fetch,
    this.browser,
  });

  final Future<File?> Function() pickFile;
  final Future<ImportedCharacter> Function(Uri url)? fetch;

  /// Makes the browser window reader; [SoulkynBrowser] unless a test
  /// replaces it.
  final SoulkynBrowser Function()? browser;

  @override
  State<SoulkynImportDialog> createState() => _SoulkynImportDialogState();
}

class _SoulkynImportDialogState extends State<SoulkynImportDialog> {
  final _link = TextEditingController();
  bool _guide = false;
  bool _busy = false;
  bool _copied = false;
  String? _error;

  /// Why the link didn't work, shown above the exporter steps.
  String? _reason;

  /// The open browser window, while the page is read there.
  SoulkynBrowser? _browser;

  /// "This is my character": read its editor page, which shows everything
  /// but needs the owner logged in, so it always goes through the window.
  bool _mine = false;

  /// The sign-in link from Soulkyn's email, pasted while the window is open.
  final _loginLink = TextEditingController();
  String? _loginError;

  /// While an owner signs in, a sign-in link copied from the email is
  /// picked up from the clipboard, so copying it is enough.
  Timer? _clipboardWatch;
  String? _lastClip;

  void _watchClipboard() {
    _clipboardWatch?.cancel();
    _lastClip = null;
    var first = true;
    _clipboardWatch = Timer.periodic(const Duration(seconds: 1), (_) async {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      final clip = text?.trim();
      // What was there before the window opened isn't a new link.
      if (first) {
        first = false;
        _lastClip = clip;
        return;
      }
      if (clip == null || clip == _lastClip) return;
      _lastClip = clip;
      if (SoulkynBrowser.looksLikeSignInLink(clip) &&
          mounted &&
          _browser != null) {
        _loginLink.text = clip;
        await _openLoginLink();
      }
    });
  }

  Future<void> _openLoginLink() async {
    final ok = await _browser?.openLink(_loginLink.text) ?? false;
    if (!mounted) return;
    setState(() {
      _loginError = ok ? null : 'Paste the whole link, starting with https://';
      if (ok) _loginLink.clear();
    });
  }

  @override
  void dispose() {
    _clipboardWatch?.cancel();
    _browser?.close();
    _loginLink.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final url = SoulkynLink.parse(_link.text);
    if (url == null) {
      setState(
        () => _error =
            'That is not a Soulkyn character link. It looks like '
            'https://soulkyn.com/@name.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_mine) {
      await _browse(SoulkynLink.editLink(url), editor: true);
      if (mounted) setState(() => _busy = false);
      return;
    }
    final reader = SoulkynLink();
    try {
      final c = await (widget.fetch ?? reader.fetch)(url);
      if (mounted) Navigator.pop(context, c);
    } on SoulkynLinkFailed {
      reader.close();
      if (mounted) await _browse(url);
    } on ImportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      reader.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reads the page in a browser window; the exporter steps if that fails.
  Future<void> _browse(Uri url, {bool editor = false}) async {
    final b = (widget.browser ?? SoulkynBrowser.new)();
    setState(() => _browser = b);
    if (editor) _watchClipboard();
    try {
      final c = await b.read(url, editor: editor);
      if (mounted) Navigator.pop(context, c);
    } on SoulkynLinkFailed catch (e) {
      // Switching to the exporter by hand closes the window too.
      if (mounted && !_guide) {
        setState(() {
          _guide = true;
          _reason = e.message;
        });
      }
    } on ImportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      _clipboardWatch?.cancel();
      if (mounted) setState(() => _browser = null);
    }
  }

  void _useExporter() {
    setState(() {
      _guide = true;
      _reason = null;
    });
    _browser?.close();
  }

  Future<void> _copy() async {
    await Clipboard.setData(const ClipboardData(text: soulkynExporter));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _choose() async {
    final f = await widget.pickFile();
    if (f != null && mounted) Navigator.pop(context, f);
  }

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 13, height: 1.45);
    final muted = TextStyle(fontSize: 13, color: context.palette.textMuted);
    Widget step(int n, String text, [Widget? action]) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            child: Text('$n', style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: small),
                if (action != null) ...[const SizedBox(height: 6), action],
              ],
            ),
          ),
        ],
      ),
    );

    final browser = _browser;
    final Widget link = browser != null && !_guide
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _mine
                    ? 'The character\'s Edit page is open in a browser window. '
                          'Log in to Soulkyn there if it asks. The import goes '
                          'on by itself; nothing is changed on Soulkyn.'
                    : 'The app couldn\'t read the page directly, so it opened '
                          'it in a browser window. If Soulkyn asks you to '
                          'confirm you are human, do it there. The import goes '
                          'on by itself.',
                style: small,
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: browser.status,
                      builder: (_, s, _) => Text(s, style: muted),
                    ),
                  ),
                ],
              ),
              if (_mine) ...[
                const SizedBox(height: 14),
                const Text(
                  'Signing in by email? Don\'t click the link in the email, '
                  'just copy it: VoxCordis notices and opens it in the window. '
                  'Or paste it here.',
                  style: small,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _loginLink,
                        onSubmitted: (_) => _openLoginLink(),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Link from the email',
                          errorText: _loginError,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: _openLoginLink,
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: browser.readNow,
                    child: const Text('Read the page now'),
                  ),
                  TextButton(
                    onPressed: _useExporter,
                    child: const Text('Use the exporter instead'),
                  ),
                ],
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Paste the link to the character\'s page.', style: muted),
              const SizedBox(height: 12),
              TextField(
                controller: _link,
                autofocus: true,
                enabled: !_busy,
                onSubmitted: (_) => _import(),
                decoration: InputDecoration(
                  hintText: 'https://soulkyn.com/@name',
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _mine,
                onChanged: _busy ? null : (v) => setState(() => _mine = v!),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('This is my character'),
                subtitle: const Text(
                  'Reads its Edit page too: identity, clothing, location, the '
                  'whole story and chat examples. You log in to Soulkyn in a '
                  'window the app opens. Otherwise only the public page comes '
                  'over.',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy ? null : _useExporter,
                  child: const Text('Use the exporter or a .json file instead'),
                ),
              ),
            ],
          );

    return AlertDialog(
      title: Text(_guide ? 'Export from Soulkyn' : 'Import from Soulkyn'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 480,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _guide
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_reason != null) ...[
                        Text(
                          '$_reason The exporter reads the page in your own '
                          'browser instead:',
                          style: muted,
                        ),
                        const SizedBox(height: 14),
                      ],
                      step(
                        1,
                        'Copy the exporter.',
                        FilledButton.tonalIcon(
                          onPressed: _copy,
                          icon: Icon(
                            _copied ? Icons.check_rounded : Icons.copy_rounded,
                          ),
                          label: Text(_copied ? 'Copied' : 'Copy exporter'),
                        ),
                      ),
                      step(
                        2,
                        'In your browser, add a new bookmark and paste it as the '
                        'address (URL). Name it something like "Export to '
                        'VoxCordis". You only do this once.',
                      ),
                      step(
                        3,
                        'Open the character\'s page on Soulkyn and click the '
                        'bookmark. It saves a .json file. If the page shows a '
                        'custom profile, switch it to the default view first. '
                        'On your own character\'s Edit page it reads every '
                        'field.',
                      ),
                      step(
                        4,
                        'Choose that file here.',
                        FilledButton.icon(
                          onPressed: _choose,
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('Choose the file'),
                        ),
                      ),
                      Text(
                        'The exporter only reads the page you are on and saves '
                        'a file. It sends nothing anywhere.',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.palette.textMuted,
                        ),
                      ),
                    ],
                  )
                : link,
          ),
        ),
      ),
      actions: [
        if (_guide)
          TextButton(
            onPressed: () => setState(() => _guide = false),
            child: const Text('Back to the link'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (!_guide && browser == null)
          FilledButton(
            onPressed: _busy ? null : _import,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Import'),
          ),
      ],
    );
  }
}

/// Offers the picture an imported character links to as its portrait.
/// Nothing is fetched until the human presses Download.
class PortraitDownload extends StatefulWidget {
  const PortraitDownload({
    super.key,
    required this.url,
    required this.onPortrait,
    this.download,
  });

  final Uri url;
  final ValueChanged<File> onPortrait;

  /// Fetches the picture; [AvatarDownload] unless a test replaces it.
  final Future<File> Function(Uri url)? download;

  @override
  State<PortraitDownload> createState() => _PortraitDownloadState();
}

class _PortraitDownloadState extends State<PortraitDownload> {
  bool _downloading = false;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    final client = AvatarDownload();
    try {
      final file = await (widget.download ?? client.fetch)(widget.url);
      widget.onPortrait(file);
    } on ImportException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'The picture could not be downloaded.';
    } finally {
      client.close();
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(fontSize: 12, color: context.palette.textMuted);
    return _Box(
      icon: Icons.image_outlined,
      children: [
        Text(
          'The import links to a picture on ${widget.url.host}. Use it as the '
          'portrait? Nothing is fetched until you press the button.',
          style: small,
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _downloading ? null : _download,
          icon: _downloading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_rounded),
          label: const Text('Download picture'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: const TextStyle(fontSize: 12, color: Colors.redAccent),
          ),
        ],
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.icon, required this.children, this.color});

  final IconData icon;
  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// The desk files that are neither notes nor pictures, each off until the
/// human ticks it, with what such a file can do.
class _OtherDeskFiles extends StatefulWidget {
  const _OtherDeskFiles(this.nemini);

  final NeminiExtras nemini;

  @override
  State<_OtherDeskFiles> createState() => _OtherDeskFilesState();
}

class _OtherDeskFilesState extends State<_OtherDeskFiles> {
  @override
  Widget build(BuildContext context) {
    final n = widget.nemini;
    final runnable = n.otherFiles.where(SystemTools.isRunnable).length;
    final muted = TextStyle(fontSize: 12, color: context.palette.textMuted);
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.orangeAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${n.otherFiles.length} other desk '
                  '${n.otherFiles.length == 1 ? 'file' : 'files'}, left out '
                  'unless you tick them',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            runnable > 0
                ? 'Scripts and programs run as you when opened: they can '
                      'read, change, delete or send anything you can. With '
                      'system access on, your companion can ask to open '
                      'them (you are asked every time). Only bring the ones '
                      'you know and trust.'
                : 'These aren\'t notes or pictures, so the companion can\'t '
                      'read them; they would just sit in its folder.',
            style: muted,
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            tristate: true,
            value: n.chosenOthers.isEmpty
                ? false
                : n.chosenOthers.length == n.otherFiles.length
                ? true
                : null,
            // A partly ticked list ticks everything on a press.
            onChanged: (_) => setState(() {
              if (n.chosenOthers.length == n.otherFiles.length) {
                n.chosenOthers.clear();
              } else {
                n.chosenOthers.addAll(n.otherFiles);
              }
            }),
            title: Text(
              'Bring all ${n.otherFiles.length}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final f in n.otherFiles)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 16),
                    value: n.chosenOthers.contains(f),
                    onChanged: (v) => setState(
                      () =>
                          v! ? n.chosenOthers.add(f) : n.chosenOthers.remove(f),
                    ),
                    title: Text(
                      f,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: SystemTools.isRunnable(f)
                        ? const Text(
                            'Script or program: runs code when opened',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orangeAccent,
                            ),
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
