import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/desk/pictures.dart';
import '../../data/desk/shared_files.dart';
import '../../data/message_repository.dart';
import '../../data/settings.dart';
import '../../services/llm_providers.dart';
import '../../services/sight.dart';
import '../../theme/app_theme.dart';
import 'chat_controller.dart';
import 'chat_text.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat});

  final ChatController chat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Pictures picked to go with the next message.
  final _pending = <String>[];

  /// Text files picked to go with the next message.
  final _pendingFiles = <String>[];

  /// Files are being dragged over the chat.
  bool _dropping = false;

  ChatController get _chat => widget.chat;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onChat);
    _input.addListener(_onTyping);
    _jumpToEnd();
  }

  @override
  void dispose() {
    _chat.removeListener(_onChat);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Typing keeps the model loaded, and loads it again when it was let go
  /// to free the graphics card, so it's ready by the time they send.
  void _onTyping() {
    final services = AppScope.of(context);
    services.runtime.touch(services.settings.value, warm: true);
  }

  void _onChat() {
    // A past day opens at its start; the live chat follows the newest reply.
    if (_chat.viewingDay != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
      return;
    }
    // Follow the reply only while the human is at the bottom: scrolled up
    // to read, they stay put. While words stream in, jump rather than
    // start a new scroll animation every frame.
    final pos = _scroll.hasClients ? _scroll.position : null;
    final following =
        pos == null || pos.maxScrollExtent - pos.pixels < _followSlack;
    if (!following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (_chat.busy) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// How far from the bottom still counts as reading the newest message.
  static const _followSlack = 120.0;

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text;
    final nothing =
        text.trim().isEmpty && _pending.isEmpty && _pendingFiles.isEmpty;
    if (nothing || _chat.busy) return;
    final images = [..._pending];
    final files = [..._pendingFiles];
    if (images.isNotEmpty && !await _okToSendPictures()) return;
    _input.clear();
    setState(() {
      _pending.clear();
      _pendingFiles.clear();
    });
    _chat.send(text, images: images, files: files);
  }

  /// The first time pictures would go to a server-hosted brain, says so
  /// and asks. True when they may go.
  Future<bool> _okToSendPictures() async {
    final store = AppScope.of(context).settings;
    final s = store.value;
    if (!Sight.picturesLeave(s) || s.picturesToServerOk) return true;
    final provider = LlmProvider.forEndpoint(s.llmEndpoint);
    final where = provider == LlmProvider.custom
        ? Uri.tryParse(s.llmEndpoint)?.host ?? s.llmEndpoint
        : provider.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.image_outlined),
        title: Text('Send pictures to $where?'),
        content: SizedBox(
          width: 420,
          child: Text(
            '${s.companionName}\'s brain is server-hosted, so the pictures '
            'you share go to $where with your message, for the model to look '
            'at. Like your messages, they are handled under $where\'s terms.'
            '\n\nIf the model can\'t see, Eyes describes them on this '
            'computer instead (Settings → Brain).',
            style: const TextStyle(height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await store.update(store.value.copyWith(picturesToServerOk: true));
    return true;
  }

  Future<void> _pickFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Pictures and text files',
          extensions: [...Pictures.extensions, ...SharedFiles.textExtensions],
        ),
      ],
    );
    await _addPaths([for (final f in files) f.path]);
  }

  /// Sorts picked, dropped or pasted files into pictures and text files,
  /// and says which can't be shared.
  Future<void> _addPaths(List<String> paths) async {
    final refused = <String>[];
    final pictures = <String>[], texts = <String>[];
    for (final path in paths) {
      switch (await SharedFiles.kindOf(path)) {
        case SharedKind.picture:
          pictures.add(path);
        case SharedKind.text:
          texts.add(path);
        case null:
          refused.add(p.basename(path));
      }
    }
    if (!mounted) return;
    setState(() {
      _pending.addAll(pictures.where((x) => !_pending.contains(x)));
      _pendingFiles.addAll(texts.where((x) => !_pendingFiles.contains(x)));
    });
    if (refused.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${refused.join(', ')}: only pictures (PNG, JPEG, WebP) and '
            'text files can be shared for now.',
          ),
        ),
      );
    }
  }

  /// Ctrl+V: files copied in the file manager and copied pictures are
  /// added to the message; text is pasted into it as usual.
  Future<void> _paste() async {
    final context = primaryFocus?.context;
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) return await _addPaths(files);
      if (!await Clipboard.hasStrings()) {
        final bytes = await Pasteboard.image;
        final picture = bytes == null ? null : Sight.normalizePasted(bytes);
        if (picture != null) {
          final dir = await Directory.systemTemp.createTemp('voxcordis-paste');
          final file = File(p.join(dir.path, 'pasted.png'));
          await file.writeAsBytes(picture);
          return await _addPaths([file.path]);
        }
      }
    } on Object {
      // The clipboard couldn't be read as files or a picture: paste text.
    }
    if (context != null && context.mounted) {
      Actions.maybeInvoke(
        context,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }

  Future<void> _confirmDelete(ChatMessage m) async {
    final mine = m.role == 'user';
    final title = mine ? 'Delete your message?' : 'Delete this reply?';
    final after = await _chat.countAfter(m);
    if (!mounted) return;
    if (after == 0) {
      final question = _chat.questionFor(m);
      if (await _confirm(
        title: title,
        body: question == null
            ? 'It is removed from the chat history for good.'
            : 'Your message it answered goes with it, so the chat doesn\'t '
                  'end on an unanswered message. Both are removed from the '
                  'chat history for good.',
        action: 'Delete',
      )) {
        await (question == null ? _chat.delete(m) : _chat.deleteFrom(question));
      }
      return;
    }
    final later = after == 1 ? '1 later message' : '$after later messages';
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Text(
            'There ${after == 1 ? 'is' : 'are'} $later after it. You can '
            'delete only this one, or this one and everything after it, '
            'to pick the chat up again from here. Deleted messages are '
            'removed from the chat history for good.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, _DeleteChoice.only),
            child: const Text('Only this one'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _DeleteChoice.fromHere),
            child: Text('This and $later'),
          ),
        ],
      ),
    );
    switch (choice) {
      case _DeleteChoice.only:
        await _chat.delete(m);
      case _DeleteChoice.fromHere:
        await _chat.deleteFrom(m);
      case null:
        break;
    }
  }

  Future<void> _confirmRegenerate() async {
    if (await _confirm(
      title: 'Write a new reply?',
      body: 'The current reply is deleted and replaced by a new one.',
      action: 'Regenerate',
    )) {
      await _chat.regenerate();
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 380, child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings.value;
    final accent = Theme.of(context).colorScheme.primary;
    // Pictures and text files dropped anywhere on the chat go with the
    // next message.
    return DropTarget(
      enable: settings.isSetUp,
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (d) {
        setState(() => _dropping = false);
        _addPaths([for (final f in d.files) f.path]);
      },
      child: Stack(
        children: [
          _chatColumn(settings, accent),
          if (_dropping)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    border: Border.all(color: accent, width: 2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Drop to share with ${settings.companionName}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chatColumn(AppSettings settings, Color accent) {
    return ListenableBuilder(
      listenable: _chat,
      builder: (context, _) {
        final msgs = _chat.messages;
        final lastAssistant = msgs.isNotEmpty && msgs.last.role == 'assistant'
            ? msgs.last.id
            : null;
        return Column(
          children: [
            if (_chat.viewingDay != null)
              _DayBanner(day: _chat.viewingDay!, onBack: _chat.load),
            Expanded(
              child: msgs.isEmpty
                  ? _EmptyState(
                      text: settings.isSetUp
                          ? 'Say hello to ${settings.companionName}.'
                          : 'Pick a companion folder and a model in Settings to start.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[i];
                        final newDay =
                            i == 0 ||
                            !DateUtils.isSameDay(msgs[i - 1].ts, m.ts);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (newDay) _DaySeparator(day: m.ts),
                            _Bubble(
                              key: ValueKey(m.id),
                              message: m,
                              folder: settings.companionFolder,
                              live: _chat.busy && i == msgs.length - 1,
                              thinkingLive:
                                  _chat.busy &&
                                  i == msgs.length - 1 &&
                                  _chat.phase == ChatPhase.thinking,
                              onDelete: _chat.busy
                                  ? null
                                  : () => _confirmDelete(m),
                              onRegenerate:
                                  m.id == lastAssistant &&
                                      !_chat.busy &&
                                      _chat.viewingDay == null
                                  ? _confirmRegenerate
                                  : null,
                            ),
                          ],
                        );
                      },
                    ),
            ),
            if (_chat.busy && _chat.phase != ChatPhase.idle)
              _StatusLine(
                phase: _chat.phase,
                name: settings.companionName,
                reading: _chat.reading,
              )
            else if (_chat.toolNote != null || _chat.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(
                      _chat.error != null
                          ? Icons.error_outline_rounded
                          : Icons.auto_awesome_outlined,
                      size: 16,
                      color: _chat.error != null
                          ? Theme.of(context).colorScheme.error
                          : context.palette.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _chat.error != null
                          // Selectable, so the whole error can be copied.
                          ? SelectableText(
                              _chat.error!,
                              maxLines: 2,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.palette.textMuted,
                              ),
                            )
                          : Text(
                              _chat.toolNote!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.palette.textMuted,
                              ),
                            ),
                    ),
                    if (_chat.error case final error?) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Copy error',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: error));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Error copied')),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded),
                      ),
                    ],
                    if (_chat.canRetry)
                      TextButton.icon(
                        onPressed: _chat.retry,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            if (_pending.isNotEmpty || _pendingFiles.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final path in _pending)
                      _PendingPicture(
                        path: path,
                        onRemove: () => setState(() => _pending.remove(path)),
                      ),
                    for (final path in _pendingFiles)
                      InputChip(
                        avatar: const Icon(Icons.description_outlined),
                        label: Text(p.basename(path)),
                        onDeleted: () =>
                            setState(() => _pendingFiles.remove(path)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: CallbackShortcuts(
                bindings: {
                  // Enter sends; Shift+Enter makes a new line.
                  const SingleActivator(LogicalKeyboardKey.enter): _send,
                  const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                      _paste,
                  const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                      _paste,
                },
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  enabled: settings.isSetUp,
                  decoration: InputDecoration(
                    hintText: _chat.viewingDay != null
                        ? 'Write to return to today…'
                        : 'Message ${settings.companionName}…',
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: IconButton(
                        onPressed: settings.isSetUp && !_chat.busy
                            ? _pickFiles
                            : null,
                        tooltip: 'Share a picture or file',
                        icon: const Icon(Icons.attach_file_rounded),
                      ),
                    ),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      // While a reply is coming, the button stops it.
                      child: IconButton.filled(
                        onPressed: _chat.busy
                            ? (_chat.stopping ? null : _chat.stop)
                            : _send,
                        tooltip: _chat.busy ? 'Stop' : 'Send',
                        // The scheme's onPrimary can sit too close to a
                        // light accent; pick the arrow colour by contrast.
                        style: IconButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: accent.computeLuminance() > 0.35
                              ? const Color(0xFF15121F)
                              : Colors.white,
                          disabledBackgroundColor: accent.withValues(
                            alpha: 0.3,
                          ),
                        ),
                        icon: Icon(
                          _chat.busy
                              ? Icons.stop_rounded
                              : Icons.arrow_upward_rounded,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: 0.85,
          child: Image.asset(AppTheme.heartMark, width: 120),
        ),
        const SizedBox(height: 18),
        Text(text, style: TextStyle(color: context.palette.textMuted)),
      ],
    ),
  );
}

class _DayBanner extends StatelessWidget {
  const _DayBanner({required this.day, required this.onBack});

  final DateTime day;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
    child: Row(
      children: [
        Icon(Icons.history_rounded, size: 18, color: context.palette.textMuted),
        const SizedBox(width: 8),
        Text(
          DateFormat('EEEE d MMMM y').format(day),
          style: TextStyle(color: context.palette.textMuted),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.south_rounded, size: 16),
          label: const Text('Back to now'),
        ),
      ],
    ),
  );
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final label = DateUtils.isSameDay(day, DateTime.now())
        ? 'Today'
        : DateFormat('EEEE d MMMM').format(day);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: context.palette.glassBorder)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: context.palette.textMuted),
            ),
          ),
          Expanded(child: Divider(color: context.palette.glassBorder)),
        ],
      ),
    );
  }
}

enum _DeleteChoice { only, fromHere }

/// One message. Hovering shows its time and actions: copy, delete, and on the
/// newest reply, regenerate.
class _Bubble extends StatefulWidget {
  const _Bubble({
    super.key,
    required this.message,
    this.folder,
    this.live = false,
    this.thinkingLive = false,
    this.onDelete,
    this.onRegenerate,
  });

  final ChatMessage message;

  /// The companion folder, where shared pictures live.
  final String? folder;

  /// The reply is still being written into this message.
  final bool live;

  /// The model is still reasoning into this message.
  final bool thinkingLive;
  final VoidCallback? onDelete;
  final VoidCallback? onRegenerate;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final mine = message.role == 'user';
    final accent = Theme.of(context).colorScheme.primary;
    final pictures = Pictures.inText(message.content);
    final files = SharedFiles.inText(message.content);
    final text = pictures.isEmpty && files.isEmpty
        ? message.content
        : SharedFiles.withoutMarkers(message.content);

    final actions = AnimatedOpacity(
      opacity: _hover && message.content.isNotEmpty ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            DateFormat.Hm().format(message.ts),
            style: TextStyle(fontSize: 11, color: context.palette.textMuted),
          ),
          _Action(
            icon: Icons.copy_rounded,
            tooltip: 'Copy',
            onTap: () =>
                Clipboard.setData(ClipboardData(text: message.content)),
          ),
          if (widget.onRegenerate != null)
            _Action(
              icon: Icons.refresh_rounded,
              tooltip: 'Regenerate',
              onTap: widget.onRegenerate!,
            ),
          if (widget.onDelete != null)
            _Action(
              icon: Icons.delete_outline_rounded,
              tooltip: 'Delete',
              onTap: widget.onDelete!,
            ),
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        ),
        // Actions sit beside the bubble so hovering never shifts the layout.
        child: Row(
          mainAxisAlignment: mine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: actions,
              ),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 620),
                margin: const EdgeInsets.symmetric(vertical: 5),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: mine
                      ? accent.withValues(alpha: 0.30)
                      : context.palette.bubble,
                  borderRadius: BorderRadius.circular(18).copyWith(
                    bottomRight: mine ? const Radius.circular(6) : null,
                    bottomLeft: mine ? null : const Radius.circular(6),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.reasoning case final r? when r.isNotEmpty)
                      _Thoughts(text: r, live: widget.thinkingLive),
                    if (pictures.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final rel in pictures)
                              _SharedPicture(
                                file: widget.folder == null
                                    ? null
                                    : Pictures.fileIn(widget.folder!, rel),
                              ),
                          ],
                        ),
                      ),
                    if (files.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final rel in files)
                              _SharedFile(folder: widget.folder, path: rel),
                          ],
                        ),
                      ),
                    if (text.isNotEmpty)
                      SelectableText.rich(
                        formatChat(
                          text,
                          actionColor: Color.lerp(
                            context.palette.text,
                            accent,
                            0.7,
                          )!,
                          codeFill: context.palette.codeFill,
                        ),
                        style: const TextStyle(height: 1.4),
                      )
                    else if (widget.live &&
                        message.reasoning?.isNotEmpty != true)
                      const _Typing(),
                  ],
                ),
              ),
            ),
            if (!mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: actions,
              ),
          ],
        ),
      ),
    );
  }
}

/// A picture the human shared, from the companion's folder.
class _SharedPicture extends StatelessWidget {
  const _SharedPicture({required this.file});

  final File? file;

  @override
  Widget build(BuildContext context) {
    final f = file;
    if (f == null || !f.existsSync()) {
      return Text(
        'Picture missing from the folder',
        style: TextStyle(fontSize: 12, color: context.palette.textMuted),
      );
    }
    // A fixed size keeps the chat from jumping when the picture loads;
    // a click opens the whole picture.
    return Tooltip(
      message: 'Open picture',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => launchUrl(Uri.file(f.path)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(f, width: 220, height: 220, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}

/// A text file the human shared. A click shows it in its folder: opening
/// the file itself could run it, if it is a script.
class _SharedFile extends StatelessWidget {
  const _SharedFile({required this.folder, required this.path});

  final String? folder;
  final String path;

  @override
  Widget build(BuildContext context) {
    final file = folder == null ? null : SharedFiles.fileIn(folder!, path);
    return ActionChip(
      avatar: const Icon(Icons.description_outlined),
      label: Text(p.posix.basename(path)),
      tooltip: 'Show in folder',
      onPressed: file == null
          ? null
          : () => launchUrl(Uri.directory(file.parent.path)),
    );
  }
}

/// A picked picture waiting for the next message, with a remove button.
class _PendingPicture extends StatelessWidget {
  const _PendingPicture({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(File(path), width: 64, height: 64, fit: BoxFit.cover),
      ),
      Positioned(
        top: -8,
        right: -8,
        child: IconButton.filledTonal(
          onPressed: onRemove,
          tooltip: 'Remove',
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.close_rounded),
        ),
      ),
    ],
  );
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    iconSize: 15,
    visualDensity: VisualDensity.compact,
    color: context.palette.textMuted,
    icon: Icon(icon),
  );
}

/// Three dots pulsing while the reply hasn't started.
class _Typing extends StatefulWidget {
  const _Typing({this.size = 7});

  final double size;

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: widget.size,
            height: widget.size,
            margin: EdgeInsets.symmetric(
              horizontal: widget.size / 3.5,
              vertical: widget.size < 6 ? 0 : 6,
            ),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: context.palette.text.withValues(
                alpha: 0.3 + 0.6 * _pulse((_c.value - i * 0.18) % 1),
              ),
            ),
          ),
      ],
    ),
  );

  static double _pulse(double t) => t < 0.5 ? t * 2 : (1 - t) * 2;
}

/// "Aria is thinking…" above the input while a reply is on its way.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.phase, required this.name, this.reading});

  final ChatPhase phase;
  final String name;

  /// How far through reading the chat, when the runtime reports it.
  final double? reading;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (phase) {
      ChatPhase.waking => (Icons.hourglass_top_rounded, 'Waking $name up'),
      ChatPhase.thinking => (
        Icons.psychology_outlined,
        switch (reading) {
          final r? when r < 1 =>
            '$name is reading the chat · ${(r * 100).round()}%',
          _ => '$name is thinking',
        },
      ),
      ChatPhase.typing => (Icons.edit_outlined, '$name is typing'),
      ChatPhase.remembering => (
        Icons.auto_awesome_outlined,
        '$name is updating memories',
      ),
      ChatPhase.looking => (
        Icons.visibility_outlined,
        '$name is looking at the picture',
      ),
      ChatPhase.idle => (Icons.circle, ''),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Row(
          key: ValueKey(phase),
          children: [
            Icon(icon, size: 16, color: context.palette.textMuted),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(fontSize: 12, color: context.palette.textMuted),
            ),
            const SizedBox(width: 2),
            const _Typing(size: 4),
          ],
        ),
      ),
    );
  }
}

/// A small "Thoughts" tab inside a reply; opens into a short scrollable box
/// so long reasoning never stretches the chat.
class _Thoughts extends StatefulWidget {
  const _Thoughts({required this.text, required this.live});

  final String text;
  final bool live;

  @override
  State<_Thoughts> createState() => _ThoughtsState();
}

class _ThoughtsState extends State<_Thoughts> {
  bool _open = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_Thoughts old) {
    super.didUpdateWidget(old);
    // While open and live, follow the newest thought.
    if (_open && widget.live) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.palette.textMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: context.palette.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(widget.live ? 'Thinking' : 'Thoughts', style: muted),
                  if (widget.live) const _Typing(size: 4),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: context.palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: !_open
                ? const SizedBox.shrink()
                : Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                    decoration: BoxDecoration(
                      color: const Color(0x14000000),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: context.palette.glassBorder),
                    ),
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.only(right: 10),
                        child: SelectableText(
                          widget.text.trim(),
                          style: muted.copyWith(height: 1.45),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
