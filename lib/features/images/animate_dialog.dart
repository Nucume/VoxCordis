import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/images/image_catalog.dart';
import '../../services/runtime/gpu_info.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';

/// What the human chose to make a clip from a picture.
typedef AnimateChoice = ({String prompt, int seconds, String modelId});

/// "Bring it to life": what happens, which video model, and how long, on a
/// ruler that colours what the graphics card is likely to manage.
class AnimateDialog extends StatefulWidget {
  const AnimateDialog({
    super.key,
    required this.models,
    required this.picture,
    required this.gpu,
    this.writePrompt,
  });

  final List<VideoModel> models;
  final File picture;
  final GpuInfo gpu;

  /// Writes a model-ready prompt from the human's few words; null hides the
  /// button.
  final Future<String?> Function(String idea, VideoModel model, int seconds)?
  writePrompt;

  @override
  State<AnimateDialog> createState() => _AnimateDialogState();
}

class _AnimateDialogState extends State<AnimateDialog> {
  final _prompt = TextEditingController();
  late VideoModel _model = widget.models.first;
  late double _seconds = _startSeconds();
  bool _writing = false;
  String? _writeProblem;

  /// What the human typed before "Write it for me" replaced it.
  String? _before;

  /// 4 s, or the longest that is green when that is shorter.
  double _startSeconds() {
    final gb = widget.gpu.memoryGb;
    if (gb == null) return 4;
    return _model.safeSeconds(gb).clamp(VideoModel.shortest, 4).toDouble();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  double? get _gb => widget.gpu.memoryGb;

  Future<void> _write() async {
    final idea = _prompt.text.trim();
    if (idea.isEmpty || _writing) return;
    setState(() {
      _writing = true;
      _writeProblem = null;
    });
    String? result;
    String? problem;
    try {
      result = await widget.writePrompt!(idea, _model, _seconds.round());
      if (result == null) problem = 'The model gave nothing usable. Try again.';
    } on Object catch (e) {
      problem = 'Couldn\'t reach the chat model: $e';
    }
    if (!mounted) return;
    setState(() {
      _writing = false;
      _writeProblem = problem;
      if (result != null) {
        _before = idea;
        _prompt.text = result;
      }
    });
  }

  /// How far the card is likely to manage; everything when it is unknown.
  ({int safe, int most}) get _limits {
    final gb = _gb;
    if (gb == null) {
      return (safe: VideoModel.longest, most: VideoModel.longest);
    }
    return (safe: _model.safeSeconds(gb), most: _model.mostSeconds(gb));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12.5, color: palette.textMuted);
    const amber = Color(0xFFE0A33A);
    const green = Color(0xFF58B77C);
    final limits = _limits;
    final seconds = _seconds.round();
    final tooLong = _gb != null && seconds > limits.most;
    final stretch = _gb != null && !tooLong && seconds > limits.safe;
    final span = VideoModel.longest - VideoModel.shortest;
    int flex(int from, int to) =>
        (to - from).clamp(0, span) * 100 + 1; // never zero

    final note = tooLong && limits.most < VideoModel.shortest
        ? 'Your ${widget.gpu.label} hasn\'t the memory to turn even '
              '${VideoModel.shortest} s into a clip with ${_model.name}: it '
              'takes about ${_model.usedGb(VideoModel.shortest).round()} GB.'
        : tooLong
        ? 'Too long for your ${widget.gpu.label}: it would most likely run '
              'out of memory. About ${limits.most} s is the most it can '
              'manage with ${_model.name}.'
        : stretch
        ? 'A stretch for your ${widget.gpu.label}: it may take very long or '
              'fail. Up to about ${limits.safe} s is safe.'
        : _gb == null
        ? 'Couldn\'t read your graphics card\'s memory, so there is no limit '
              'here. Long clips need a lot of it.'
        : 'Should be fine on your ${widget.gpu.label}.';
    final noteColor = tooLong
        ? scheme.error
        : stretch
        ? amber
        : palette.textMuted;
    final accent = scheme.primary;

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ColoredBox(
              color: palette.tile,
              child: Image.file(
                widget.picture,
                fit: BoxFit.contain,
                cacheWidth: 720,
              ),
            ),
          ),
        ),
        if (widget.models.length > 1) ...[
          const SizedBox(height: 16),
          _ModelChips(
            models: widget.models,
            value: _model,
            onChanged: (m) => setState(() => _model = m),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Length', style: muted),
            const Spacer(),
            Text(
              '$seconds s',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: tooLong ? scheme.error : palette.text,
              ),
            ),
          ],
        ),
        // A glass track: a faint frosted bar with a glowing knob.
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 8,
            trackShape: const RoundedRectSliderTrackShape(),
            activeTrackColor: accent.withValues(alpha: 0.55),
            inactiveTrackColor: palette.glassBorder.withValues(alpha: 0.7),
            activeTickMarkColor: Colors.transparent,
            inactiveTickMarkColor: palette.textMuted.withValues(alpha: 0.35),
            tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 1.5),
            thumbColor: Colors.white.withValues(alpha: 0.92),
            overlayColor: accent.withValues(alpha: 0.18),
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 11,
              elevation: 6,
              pressedElevation: 10,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
          ),
          child: Slider(
            min: VideoModel.shortest.toDouble(),
            max: VideoModel.longest.toDouble(),
            divisions: span,
            label: '$seconds s',
            value: _seconds,
            onChanged: (v) => setState(() => _seconds = v),
          ),
        ),
        // The ruler: green as far as the card is likely to manage,
        // amber to the most it might, red beyond.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: flex(VideoModel.shortest, limits.safe),
                    child: ColoredBox(
                      color: green.withValues(alpha: _gb == null ? 0.25 : 0.8),
                    ),
                  ),
                  Expanded(
                    flex: flex(limits.safe, limits.most),
                    child: ColoredBox(color: amber.withValues(alpha: 0.8)),
                  ),
                  Expanded(
                    flex: flex(limits.most, VideoModel.longest),
                    child: ColoredBox(
                      color: scheme.error.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${VideoModel.shortest} s', style: muted),
              Text('${VideoModel.longest} s', style: muted),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(note, style: TextStyle(fontSize: 12.5, color: noteColor)),
        if (seconds > 5 && !_model.detailedPrompt) ...[
          const SizedBox(height: 4),
          Text(
            'Wan learned from clips of about 5 seconds; longer ones may '
            'repeat themselves or drift.',
            style: muted,
          ),
        ],
      ],
    );

    final write = widget.writePrompt;
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: TextField(
            controller: _prompt,
            autofocus: true,
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'What happens?',
              hintText: 'She smiles and tucks her hair behind her ear',
              alignLabelWithHint: true,
              filled: true,
              fillColor: palette.tile,
              contentPadding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: palette.glassBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: accent.withValues(alpha: 0.6),
                  width: 1.4,
                ),
              ),
            ),
          ),
        ),
        if (write != null) ...[
          const SizedBox(height: 8),
          _PromptCounter(length: _prompt.text.length, model: _model),
          const SizedBox(height: 8),
          Row(
            children: [
              _GlassButton(
                onPressed: _writing || _prompt.text.trim().isEmpty
                    ? null
                    : _write,
                busy: _writing,
                icon: Icons.auto_awesome,
                label: _writing ? 'Writing…' : 'Write it for me',
              ),
              const SizedBox(width: 6),
              Tooltip(
                message:
                    'Turns your idea into the detailed prompt this model '
                    'likes, written by your chat model.',
                waitDuration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: palette.textMuted,
                ),
              ),
              const Spacer(),
              if (_before != null && !_writing)
                TextButton(
                  onPressed: () => setState(() {
                    _prompt.text = _before!;
                    _before = null;
                  }),
                  child: const Text('Back to mine'),
                ),
            ],
          ),
          if (_writeProblem != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _writeProblem!,
                style: TextStyle(fontSize: 12.5, color: scheme.error),
              ),
            ),
        ],
        const SizedBox(height: 12),
        Text(
          'This takes minutes, longer for longer clips and smaller cards, '
          'and the chat model steps aside meanwhile.',
          style: muted,
        ),
      ],
    );

    return AlertDialog(
      title: const Text('Bring it to life'),
      content: SizedBox(
        width: 880,
        height: 560,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 400, child: left),
            const SizedBox(width: 28),
            Expanded(child: right),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: tooLong || _writing
              ? null
              : () => Navigator.pop<AnimateChoice>(context, (
                  prompt: _prompt.text,
                  seconds: seconds,
                  modelId: _model.id,
                )),
          icon: const Icon(Icons.movie_creation_outlined, size: 18),
          label: const Text('Make clip'),
        ),
      ],
    );
  }
}

/// A frosted pill with an accent glow: lifts under the pointer, dims when it
/// can't be pressed.
class _GlassButton extends StatefulWidget {
  const _GlassButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    this.busy = false,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool busy;

  @override
  State<_GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<_GlassButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final palette = context.palette;
    final on = widget.onPressed != null;
    final lit = on && _hover;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Opacity(
          opacity: on || widget.busy ? 1 : 0.5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: lit ? 0.42 : 0.28),
                  accent.withValues(alpha: lit ? 0.22 : 0.10),
                ],
              ),
              border: Border.all(
                color: accent.withValues(alpha: lit ? 0.75 : 0.45),
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: lit ? 0.30 : 0.12),
                  blurRadius: lit ? 18 : 10,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(widget.icon, size: 18, color: palette.text),
                const SizedBox(width: 10),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The video models as glass chips. With more than four installed, three
/// show and the rest sit behind "More"; a model picked from there takes
/// the place of "More" and the other chips squeeze to make room for its
/// name.
class _ModelChips extends StatelessWidget {
  const _ModelChips({
    required this.models,
    required this.value,
    required this.onChanged,
  });

  final List<VideoModel> models;
  final VideoModel value;
  final ValueChanged<VideoModel> onChanged;

  static const _shown = 2;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final many = models.length > _shown + 1;
    final front = many ? models.take(_shown).toList() : models;
    final rest = many ? models.skip(_shown).toList() : <VideoModel>[];
    final picked = rest.contains(value) ? value : null;
    // Natural width of each chip's label at the normal size, so the row can
    // share its width fairly and shrink every name by the same amount.
    double natural(String text, {double extra = 24}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width + extra;
    }

    final widths = [
      for (final m in front) natural(m.name),
      if (many) natural(picked?.name ?? 'More', extra: 66),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'Video model',
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            final gaps = 6.0 * (widths.length - 1);
            final need = widths.fold(0.0, (a, b) => a + b) + gaps;
            final scale = (((box.maxWidth) / need).clamp(0.8, 1.0)).toDouble();
            return Row(
              children: [
                for (final (i, m) in front.indexed) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    flex: widths[i].round(),
                    child: _ModelChip(
                      label: m.name,
                      scale: scale,
                      selected: m == value,
                      onTap: () => onChanged(m),
                    ),
                  ),
                ],
                if (many) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    flex: widths.last.round(),
                    child: GlassSelect<VideoModel?>(
                      value: picked,
                      width: double.infinity,
                      pill: true,
                      placeholder: 'More',
                      options: [for (final m in rest) GlassOption(m, m.name)],
                      onChanged: (m) {
                        if (m != null) onChanged(m);
                      },
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ModelChip extends StatefulWidget {
  const _ModelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.scale = 1,
  });

  final double scale;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final palette = context.palette;
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: on
                ? accent.withValues(alpha: 0.2)
                : _hover
                ? palette.tile
                : Colors.transparent,
            border: Border.all(
              color: on ? accent.withValues(alpha: 0.6) : palette.glassBorder,
            ),
            boxShadow: [
              if (on)
                BoxShadow(
                  color: accent.withValues(alpha: 0.15),
                  blurRadius: 10,
                ),
            ],
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14 * widget.scale,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              color: on ? palette.text : palette.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// "212 characters, about 500 suits Wan 2.2 5B": amber past what the model
/// holds on to.
class _PromptCounter extends StatelessWidget {
  const _PromptCounter({required this.length, required this.model});

  final int length;
  final VideoModel model;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final over = length > model.promptMax;
    final style = TextStyle(
      fontSize: 12.5,
      color: over ? const Color(0xFFE0A33A) : palette.textMuted,
    );
    return Text(
      over
          ? '$length characters is more than ${model.name} keeps track of '
                '(about ${model.promptChars} suits it, ${model.promptMax} at '
                'most). Shorter works better.'
          : '$length characters. About ${model.promptChars} suits '
                '${model.name}.',
      style: style,
    );
  }
}
