import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../services/voces/describer.dart';
import '../../theme/app_theme.dart';

/// The editors for worlds and characters: a page in Voces Mundi's main
/// panel, with its parts listed on the left and a live preview on the
/// right. Leaving it any way but Cancel keeps a draft.

/// Lets an editor take over the main panel. Voces Mundi's home provides
/// it; [openEditor] falls back to a page of its own elsewhere.
class VocesEditorHost extends InheritedWidget {
  const VocesEditorHost({super.key, required this.open, required super.child});

  /// Shows the page [build] makes until it calls its `done`, or until the
  /// human goes elsewhere (then with null).
  final Future<T?> Function<T>(Widget Function(void Function(T?) done) build)
  open;

  @override
  bool updateShouldNotify(VocesEditorHost oldWidget) => false;
}

/// Opens an editor page; its result once it closes.
Future<T?> openEditor<T>(
  BuildContext context,
  Widget Function(void Function(T?) done) build,
) {
  final host = context.getInheritedWidgetOfExactType<VocesEditorHost>();
  if (host != null) return host.open<T>(build);
  return Navigator.push<T>(
    context,
    MaterialPageRoute(
      builder: (route) =>
          Scaffold(body: build((value) => Navigator.pop(route, value))),
    ),
  );
}

/// One part of an editor, with its place in the list on the left.
class EditorSection {
  const EditorSection(this.label, this.icon, this.child);

  final String label;
  final IconData icon;
  final Widget child;
}

/// What Cancel asks when something was typed.
enum LeaveChoice { draft, discard }

Future<LeaveChoice?> askLeave(BuildContext context) => showDialog<LeaveChoice>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Keep this as a draft?'),
    content: const SizedBox(
      width: 420,
      child: Text(
        'What you changed here hasn\'t been saved. A draft waits for you '
        'the next time you open this editor.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Keep editing'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, LeaveChoice.discard),
        child: const Text('Discard'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, LeaveChoice.draft),
        child: const Text('Save as draft'),
      ),
    ],
  ),
);

class VocesEditorPage extends StatefulWidget {
  const VocesEditorPage({
    super.key,
    required this.title,
    required this.sections,
    required this.onCancel,
    required this.onSave,
    required this.saveLabel,
    this.preview,
    this.banner,
    this.actions = const [],
  });

  /// More buttons before Cancel (Delete).
  final List<Widget> actions;

  final String title;
  final List<EditorSection> sections;
  final VoidCallback onCancel;

  /// Null while it can't be saved yet.
  final VoidCallback? onSave;
  final String saveLabel;

  /// How it will look, beside the parts when there's room.
  final Widget? preview;

  /// Shown above the parts (a restored draft).
  final Widget? banner;

  @override
  State<VocesEditorPage> createState() => _VocesEditorPageState();
}

class _VocesEditorPageState extends State<VocesEditorPage> {
  final _scroll = ScrollController();

  /// Holds the keys (Esc, Ctrl+S) when no field has them.
  final _focus = FocusNode(debugLabel: 'editor page');
  final _viewport = GlobalKey();
  late var _keys = [for (final _ in widget.sections) GlobalKey()];
  var _active = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_track);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(VocesEditorPage old) {
    super.didUpdateWidget(old);
    if (old.sections.length != widget.sections.length) {
      _keys = [for (final _ in widget.sections) GlobalKey()];
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Lights the part the list has scrolled to.
  void _track() {
    final view = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (view == null) return;
    var active = 0;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 4) {
      active = _keys.length - 1;
    } else {
      for (var i = 0; i < _keys.length; i++) {
        final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
        if (box == null) continue;
        final top = box.localToGlobal(Offset.zero, ancestor: view).dy;
        if (top <= 80) active = i;
      }
    }
    if (active != _active) setState(() => _active = active);
  }

  void _jump(int i) {
    final c = _keys[i].currentContext;
    if (c == null) return;
    Scrollable.ensureVisible(
      c,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    ).then((_) {
      if (mounted) setState(() => _active = i);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Focus(
        focusNode: _focus,
        child: Theme(
          data: editorTheme(context),
          child: LayoutBuilder(
            builder: (context, box) {
              final nav = box.maxWidth >= 760;
              final preview = widget.preview != null && box.maxWidth >= 1000;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 18, 20, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: palette.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'If you go elsewhere, your changes wait here as a '
                                'draft.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: palette.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        ...widget.actions,
                        TextButton(
                          onPressed: widget.onCancel,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: widget.onSave,
                          child: Text(widget.saveLabel),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (nav)
                          SizedBox(
                            width: 184,
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(16, 4, 4, 16),
                              children: [
                                for (var i = 0; i < widget.sections.length; i++)
                                  _NavItem(
                                    section: widget.sections[i],
                                    on: i == _active,
                                    accent: accent,
                                    onTap: () => _jump(i),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: SingleChildScrollView(
                            key: _viewport,
                            controller: _scroll,
                            padding: EdgeInsets.fromLTRB(
                              nav ? 8 : 20,
                              4,
                              16,
                              28,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (widget.banner != null) ...[
                                  widget.banner!,
                                  const SizedBox(height: 14),
                                ],
                                for (var i = 0; i < widget.sections.length; i++)
                                  Padding(
                                    key: _keys[i],
                                    padding: const EdgeInsets.only(bottom: 14),
                                    child: EditorCard(
                                      label: widget.sections[i].label,
                                      icon: widget.sections[i].icon,
                                      child: widget.sections[i].child,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (preview)
                          SizedBox(
                            width: 300,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(4, 4, 20, 28),
                              child: widget.preview,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _save() => widget.onSave?.call();
}

/// The editor's fields stay solid on the glassy cards, so text reads as
/// well as anywhere else.
ThemeData editorTheme(BuildContext context) {
  final theme = Theme.of(context);
  final palette = context.palette;
  final light = theme.brightness == Brightness.light;
  final ground = palette.background.withValues(alpha: 1);
  return theme.copyWith(
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      fillColor: Color.alphaBlend(
        light ? const Color(0x99FFFFFF) : const Color(0x40000000),
        ground,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.text.withValues(alpha: 0.08)),
      ),
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.on,
    required this.accent,
    required this.onTap,
  });

  final EditorSection section;
  final bool on;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: on
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: 0.26),
                      accent.withValues(alpha: 0.12),
                    ],
                  )
                : null,
            border: Border.all(
              color: on ? accent.withValues(alpha: 0.5) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                section.icon,
                size: 18,
                color: on ? palette.text : palette.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  section.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    color: on ? palette.text : palette.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A glassy card for one part of an editor: a faint sheen and edge over
/// the solid panel, no blur of its own (the panel under it doesn't move).
class EditorCard extends StatelessWidget {
  const EditorCard({
    super.key,
    required this.child,
    this.label,
    this.icon,
    this.padding = const EdgeInsets.fromLTRB(18, 14, 18, 18),
    this.tint,
  });

  final String? label;
  final IconData? icon;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// A colour for the sheen (the accent, for something to notice).
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // Dark: a faint light sheen. Light: frosted white, so the card lifts
    // off the panel instead of greying it.
    final light = Theme.of(context).brightness == Brightness.light;
    final sheen = tint ?? (light ? Colors.white : palette.text);
    final (top, bottom, edge) = tint != null
        ? (0.16, 0.05, 0.35)
        : light
        ? (0.75, 0.4, 0.9)
        : (0.075, 0.025, 0.12);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            sheen.withValues(alpha: top),
            sheen.withValues(alpha: bottom),
          ],
        ),
        border: Border.all(color: sheen.withValues(alpha: edge)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: light ? 0.05 : 0.14),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) ...[
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: palette.textMuted),
                  const SizedBox(width: 8),
                ],
                Text(
                  label!,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: palette.text,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          child,
        ],
      ),
    );
  }
}

/// "We kept your draft", over a restored editor.
class DraftBanner extends StatelessWidget {
  const DraftBanner({super.key, required this.saved, required this.onDrop});

  final DateTime? saved;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return EditorCard(
      tint: accent,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 20, color: palette.text),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              saved == null
                  ? 'Your draft is back, as you left it.'
                  : 'Your draft from ${_when(saved!)} is back, as you left it.',
              style: TextStyle(color: palette.text),
            ),
          ),
          TextButton(onPressed: onDrop, child: const Text('Discard draft')),
        ],
      ),
    );
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${t.day}.${t.month}.${t.year}';
  }
}

/// "Describe it": an idea in a few words, and the chat model fills in the
/// rest. Warns when the model looks small.
class DescribeBox extends StatefulWidget {
  const DescribeBox({
    super.key,
    required this.title,
    required this.hint,
    required this.what,
    required this.onDescribe,
  });

  final String title;
  final String hint;

  /// "world" or "character", for the notices.
  final String what;

  /// Fills the editor in from the idea; an error to show, or null.
  final Future<String?> Function(String idea) onDescribe;

  @override
  State<DescribeBox> createState() => _DescribeBoxState();
}

class _DescribeBoxState extends State<DescribeBox> {
  final _idea = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _idea.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onDescribe(_idea.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final size = modelBillions(AppScope.of(context).settings.value);
    final small = size != null && size < smallModelBillions;
    return EditorCard(
      tint: accent,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: palette.text),
              const SizedBox(width: 8),
              Text(
                widget.title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: palette.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Say it in a few words and your chat model fills in the rest. '
            'You can change anything after.',
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _idea,
                  minLines: 1,
                  maxLines: 4,
                  enabled: !_busy,
                  decoration: InputDecoration(hintText: widget.hint),
                  onSubmitted: (_) => _idea.text.trim().isEmpty ? null : _go(),
                ),
              ),
              const SizedBox(width: 10),
              ListenableBuilder(
                listenable: _idea,
                builder: (context, _) => FilledButton.tonalIcon(
                  onPressed: _busy || _idea.text.trim().isEmpty ? null : _go,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(_busy ? 'Writing…' : 'Fill it in'),
                ),
              ),
            ],
          ),
          if (small) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: Color(0xFFFFC46B),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your chat model looks small (${_size(size)}). It can '
                    'fill this in, but a ${smallModelBillions.round()}B or '
                    'larger model writes a richer, more consistent '
                    '${widget.what}.',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _size(double b) => '${b == b.roundToDouble() ? b.round() : b}B';
}

/// Runs [ask] and turns a failure into words for the human.
Future<String?> describeError(Future<String?> Function() ask) async {
  try {
    return await ask();
  } on Object catch (e) {
    return 'Couldn\'t reach the model: $e';
  }
}
