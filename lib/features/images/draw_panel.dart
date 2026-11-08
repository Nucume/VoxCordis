import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/images/image_catalog.dart';
import '../../services/images/image_engine.dart';
import '../../services/images/sd_runtime.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import 'draw_presets.dart';
import 'lora_grid.dart';
import 'resizable_field.dart';

/// The panel to draw a picture by hand: the prompt, shapes and a ratio of
/// one's own, and with Advanced on the model, size, steps, guidance, seed,
/// sampler, scheduler, negative prompt and LoRAs. What is set there is
/// remembered (per model) in the settings, so the Pictures tab and Voces
/// Mundi's "Draw it" share it. It needs a model to draw with
/// ([ImageEngine.available] not empty).
class DrawPanel extends StatefulWidget {
  const DrawPanel({
    super.key,
    required this.folder,
    this.prompt,
    this.title = 'Draw something yourself',
    this.shape,
    this.onJob,
    this.onDrawn,
  });

  /// The folder the picture goes into, under `images/`.
  final String folder;

  /// What the prompt starts as.
  final String? prompt;
  final String title;

  /// The shape to start on instead of the one last used (not remembered).
  final String? shape;

  /// A drawing was queued.
  final ValueChanged<DrawJob>? onJob;

  /// A drawing is done (also after the panel is gone).
  final ValueChanged<File>? onDrawn;

  /// The width:height in [text] ("9:16", "16 9", "4x3", "9/16", "1.5:1"),
  /// or null.
  static ({double w, double h})? ratioIn(String text) =>
      _DrawPanelState.ratioIn(text);

  @override
  State<DrawPanel> createState() => _DrawPanelState();
}

class _DrawPanelState extends State<DrawPanel> {
  final _prompt = TextEditingController();
  final _negative = TextEditingController();
  final _steps = TextEditingController();
  final _cfg = TextEditingController();
  final _seed = TextEditingController();
  final _width = TextEditingController();
  final _height = TextEditingController();

  /// Width:height ("9:16"); with one set, typing one side works out the
  /// other.
  final _ratio = TextEditingController();

  /// The side typed last, which a new ratio keeps.
  bool _widthLast = false;

  /// Whether the ratio button is open for typing.
  bool _ratioOpen = false;
  final _ratioFocus = FocusNode();
  bool _advanced = false;
  bool _lorasOpen = false;
  String _shape = 'square';
  String? _model;

  /// sd-cli's sampler and scheduler picked in the advanced options, or
  /// null for the model's own.
  String? _sampler;
  String? _scheduler;

  /// Set once the panel has picked up what it was left showing; filling the
  /// fields from the saved choices must not save them back.
  bool _loaded = false;
  bool _applying = false;
  Timer? _saveTimer;
  SettingsStore? _store;

  /// LoRAs picked in the advanced options, by name, with their weight.
  final _loras = <String, double>{};
  String? _drawError;

  /// Sizes are typed in and settle on a multiple of 64 the models draw
  /// cleanly at, between these.
  static const _minSize = 256;
  static const _maxSize = 2048;

  static int _snap(int v) =>
      ((v / 64).round() * 64).clamp(_minSize, _maxSize).toInt();

  /// The size typed into [c], settled, or null to use the model's own.
  static int? _sizeIn(TextEditingController c) {
    final v = int.tryParse(c.text);
    return v == null || v == 0 ? null : _snap(v);
  }

  /// Shows the size [c] will draw at once the field is left.
  void _settle(TextEditingController c) {
    final v = _sizeIn(c);
    final text = v?.toString() ?? '';
    if (c.text != text) c.text = text;
  }

  /// The width:height in [text] ("9:16", "16 9", "4x3", "9/16", "1.5:1"),
  /// or null. Ratios past 8:1 are refused: both sides couldn't stay in 256
  /// to 2048.
  static ({double w, double h})? ratioIn(String text) {
    final m = RegExp(
      r'^\s*(\d+(?:\.\d+)?)\s*(?:[:xX/×]|\s)\s*(\d+(?:\.\d+)?)\s*$',
    ).firstMatch(text);
    if (m == null) return null;
    final w = double.parse(m[1]!);
    final h = double.parse(m[2]!);
    if (w <= 0 || h <= 0 || w / h > 8 || h / w > 8) return null;
    return (w: w, h: h);
  }

  static String _plain(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : '$v';

  /// Settles the size typed into [c] and, with a ratio set, works out the
  /// other side from it.
  void _settleSize(TextEditingController c) {
    _settle(c);
    if (c.text.isEmpty) return;
    _widthLast = c == _width;
    _followRatio();
  }

  /// Settles the ratio typed in as "w:h" (dropping one that isn't a
  /// ratio), folds the field away and sets the other side from the one
  /// typed last.
  void _settleRatio() {
    final r = ratioIn(_ratio.text);
    final text = r == null ? '' : '${_plain(r.w)}:${_plain(r.h)}';
    setState(() {
      if (_ratio.text != text) _ratio.text = text;
      _ratioOpen = false;
    });
    _followRatio();
    _saveChoices();
  }

  void _followRatio() {
    final r = ratioIn(_ratio.text);
    if (r == null) return;
    final width = _sizeIn(_width);
    final height = _sizeIn(_height);
    if (_widthLast && width != null || height == null && width != null) {
      final h = '${_snap((width * r.h / r.w).round())}';
      if (_height.text != h) _height.text = h;
    } else if (height != null) {
      final w = '${_snap((height * r.w / r.h).round())}';
      if (_width.text != w) _width.text = w;
    }
  }

  /// The size [model] draws at with nothing typed: the shape's, or with a
  /// ratio set, about the shape's pixels in that ratio.
  ({int width, int height}) _sizeFor(ImageModel model) {
    final r = ratioIn(_ratio.text);
    if (r == null) return model.sizeFor(_shape);
    final area = model.baseSize * model.baseSize;
    final w = sqrt(area * r.w / r.h);
    return (width: _snap(w.round()), height: _snap((area / w).round()));
  }

  @override
  void initState() {
    super.initState();
    _prompt.text = widget.prompt ?? '';
    _negative.addListener(_scheduleSave);
    _ratioFocus.addListener(() {
      if (!_ratioFocus.hasFocus && _ratioOpen) _settleRatio();
    });
    for (final c in [_steps, _cfg, _seed, _width, _height, _ratio]) {
      c.addListener(_numbersChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = AppScope.of(context).settings;
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) _saveChoices();
    _saveTimer?.cancel();
    for (final c in [
      _prompt,
      _negative,
      _steps,
      _cfg,
      _seed,
      _width,
      _height,
      _ratio,
    ]) {
      c.dispose();
    }
    _ratioFocus.dispose();
    super.dispose();
  }

  ImageModel _modelIn(AppSettings s, List<ImageModel> ready) =>
      ready.where((m) => m.id == _model).firstOrNull ??
      ImageCatalog.defaultFor(s, ready)!;

  /// Picks up the switch, shape, model and that model's numbers as they
  /// were left, the first time there is a model to draw with.
  void _loadOnce(AppSettings s, List<ImageModel> ready) {
    if (_loaded || ready.isEmpty) return;
    _loaded = true;
    final saved = s.draw;
    _advanced = saved.advanced;
    _lorasOpen = saved.lorasOpen;
    _shape = widget.shape ?? saved.shape;
    _model =
        (ready.where((m) => m.id == saved.model).firstOrNull ??
                ImageCatalog.defaultFor(s, ready)!)
            .id;
    _applyChoices(saved.perModel[_model] ?? const DrawChoices());
    // The size stays whichever model is picked; before it did, each model
    // kept its own, so that one is the start.
    final old = saved.perModel[_model];
    _applying = true;
    _width.text = '${saved.width ?? old?.width ?? ''}';
    _height.text = '${saved.height ?? old?.height ?? ''}';
    _ratio.text = saved.ratio ?? '';
    _applying = false;
  }

  /// Puts [c] into the fields.
  void _applyChoices(DrawChoices c) {
    _applying = true;
    _steps.text = c.steps?.toString() ?? '';
    _cfg.text = c.cfg == null ? '' : '${c.cfg}';
    _seed.text = c.seed?.toString() ?? '';
    _sampler = c.sampler;
    _scheduler = c.scheduler;
    _negative.text = c.negative;
    _loras
      ..clear()
      ..addAll(c.loras);
    _applying = false;
  }

  void _numbersChanged() {
    if (_applying || !_loaded) return;
    // The Reset button shows while a number is set.
    setState(() {});
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_applying || !_loaded) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveChoices);
  }

  /// Keeps the fields as this model's choices.
  void _saveChoices() {
    _saveTimer?.cancel();
    final store = _store;
    final id = _model;
    if (store == null || id == null || !_loaded) return;
    final now = DrawChoices(
      steps: int.tryParse(_steps.text),
      cfg: double.tryParse(_cfg.text),
      seed: int.tryParse(_seed.text),
      negative: _negative.text,
      loras: {..._loras},
      sampler: _sampler,
      scheduler: _scheduler,
    );
    var draw = store.value.draw;
    final width = _sizeIn(_width);
    final height = _sizeIn(_height);
    final ratio = ratioIn(_ratio.text) == null ? null : _ratio.text.trim();
    final sizeSame =
        draw.width == width && draw.height == height && draw.ratio == ratio;
    if ((draw.perModel[id] ?? const DrawChoices()) == now && sizeSame) return;
    if (!sizeSame) {
      draw = draw.withSize(width: width, height: height, ratio: ratio);
    }
    unawaited(
      store.update(store.value.copyWith(draw: draw.withChoices(id, now))),
    );
  }

  /// Keeps the Advanced switch, the shape or the model.
  void _remember({
    bool? advanced,
    String? shape,
    String? model,
    bool? lorasOpen,
  }) {
    final store = _store;
    if (store == null) return;
    final draw = store.value.draw;
    unawaited(
      store.update(
        store.value.copyWith(
          draw: draw.copyWith(
            advanced: advanced,
            shape: shape,
            model: model,
            lorasOpen: lorasOpen,
          ),
        ),
      ),
    );
  }

  void _pickModel(String id) {
    _saveChoices();
    final store = _store;
    setState(() {
      _model = id;
      _applyChoices(store?.value.draw.perModel[id] ?? const DrawChoices());
    });
    _remember(model: id);
  }

  void _resetNumbers() {
    setState(() {
      _applying = true;
      _width.clear();
      _height.clear();
      _steps.clear();
      _cfg.clear();
      _seed.clear();
      _ratio.clear();
      _sampler = null;
      _scheduler = null;
      _applying = false;
    });
    _saveChoices();
  }

  /// Draws at [shape]'s size: in the advanced options, typed sizes give
  /// way to it.
  void _pickShape(String shape) {
    setState(() {
      _shape = shape;
      _applying = true;
      _ratio.clear();
      _ratioOpen = false;
      if (_advanced) {
        _width.clear();
        _height.clear();
      }
      _applying = false;
    });
    _remember(shape: shape);
    _saveChoices();
  }

  Future<void> _draw(List<ImageModel> ready) async {
    final services = AppScope.of(context);
    final s = services.settings.value;
    final folder = widget.folder;
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty || ready.isEmpty) return;
    final model = _modelIn(s, ready);
    final size = _sizeFor(model);
    setState(() => _drawError = null);
    final job = services.imageEngine.draw(
      DrawJob(
        _advanced
            ? DrawRequest(
                model: model,
                prompt: prompt,
                negative: _negative.text,
                shape: _shape,
                loras: [
                  // Saved picks whose file has since gone are left out.
                  for (final e in _loras.entries)
                    if (services.imageEngine
                        .lorasFor(s)
                        .any((l) => l.name == e.key))
                      (name: e.key, weight: e.value),
                ],
                width: _sizeIn(_width) ?? size.width,
                height: _sizeIn(_height) ?? size.height,
                steps: int.tryParse(_steps.text)?.clamp(1, 150),
                cfg: double.tryParse(_cfg.text)?.clamp(0, 30).toDouble(),
                seed: int.tryParse(_seed.text),
                sampler: _sampler,
                scheduler: _scheduler,
              )
            : DrawRequest(
                model: model,
                prompt: prompt,
                shape: _shape,
                // A ratio of one's own sets the size outright.
                width: ratioIn(_ratio.text) == null ? null : size.width,
                height: ratioIn(_ratio.text) == null ? null : size.height,
              ),
        folder: folder,
        forChat: false,
      ),
    );
    widget.onJob?.call(job);
    try {
      final file = await job.done;
      widget.onDrawn?.call(file);
    } catch (e) {
      if (mounted) setState(() => _drawError = '$e');
    }
  }

  /// Saves the prompt as a favourite, or loads one.
  Future<void> _presets() async {
    final picked = await showDrawPresets(
      context,
      prompt: _prompt.text,
      negative: _negative.text,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _prompt.text = picked.prompt;
      if (picked.negative.isNotEmpty) _negative.text = picked.negative;
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final engine = services.imageEngine;
    return ListenableBuilder(
      listenable: Listenable.merge([services.settings, engine]),
      builder: (context, _) {
        final s = services.settings.value;
        final ready = engine.available(s);
        _loadOnce(s, ready);
        if (_loaded && ready.isNotEmpty && ready.every((m) => m.id != _model)) {
          // The model it was left on isn't there any more (the engine was
          // changed): take the first one's own choices once built.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || ready.any((m) => m.id == _model)) return;
            final id = ImageCatalog.defaultFor(s, ready)!.id;
            setState(() {
              _model = id;
              _applyChoices(s.draw.perModel[id] ?? const DrawChoices());
            });
          });
        }
        if (ready.isEmpty) return const SizedBox.shrink();
        return _panel(s, ready, engine);
      },
    );
  }

  /// Square, portrait and landscape at [model]'s sizes (832 x 1216 and
  /// 1024 x 1024 for SDXL-sized models), then a fourth button for a ratio
  /// of one's own, which opens into a small field. In the advanced options
  /// no shape is lit while a typed size matches none of them.
  Widget _shapePicker(ImageModel model) {
    ({int width, int height}) sizeOf(String shape) => model.sizeFor(shape);
    final ratio = ratioIn(_ratio.text);
    String? lit = _shape;
    if (ratio != null) {
      lit = null;
    } else if (_advanced &&
        (_width.text.isNotEmpty || _height.text.isNotEmpty)) {
      final now = sizeOf(_shape);
      final w = _sizeIn(_width) ?? now.width;
      final h = _sizeIn(_height) ?? now.height;
      lit = [
        'square',
        'portrait',
        'landscape',
      ].where((sh) => sizeOf(sh) == (width: w, height: h)).firstOrNull;
    }
    ButtonSegment<String> segment(String shape, String name, IconData icon) {
      final size = sizeOf(shape);
      return ButtonSegment(
        value: shape,
        icon: Icon(icon),
        tooltip: '$name, ${size.width} x ${size.height}',
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          emptySelectionAllowed: true,
          segments: [
            segment('square', 'Square', Icons.crop_square_rounded),
            segment('portrait', 'Portrait', Icons.crop_portrait_rounded),
            segment('landscape', 'Landscape', Icons.crop_landscape_rounded),
          ],
          selected: {?lit},
          onSelectionChanged: (v) {
            // Clicking the lit one again keeps it.
            _pickShape(v.isEmpty ? _shape : v.single);
          },
        ),
        const SizedBox(width: 6),
        _ratioButton(model, lit: ratio != null),
      ],
    );
  }

  /// The fourth shape button: a ratio of one's own ("9:16", "16 9",
  /// "4/3"). It opens into a field when clicked and shows the ratio while
  /// one is set.
  Widget _ratioButton(ImageModel model, {required bool lit}) {
    final scheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    final size = _sizeFor(model);
    final text = TextStyle(fontSize: 14, color: palette.text);
    return Tooltip(
      message: lit
          ? 'Ratio ${_ratio.text}, ${size.width} x ${size.height}'
          : 'Your own ratio, like 9:16, 16 9 or 4/3',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        key: const ValueKey('ratio-button'),
        color: lit ? scheme.secondaryContainer : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: scheme.outline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            setState(() => _ratioOpen = true);
            _ratioFocus.requestFocus();
          },
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.aspect_ratio_rounded,
                    size: 18,
                    color: lit ? scheme.onSecondaryContainer : palette.text,
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: _ratioOpen
                        ? Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: SizedBox(
                              width: 64,
                              child: TextField(
                                controller: _ratio,
                                focusNode: _ratioFocus,
                                style: text,
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[\d.:xX/× ]'),
                                  ),
                                  LengthLimitingTextInputFormatter(11),
                                ],
                                onSubmitted: (_) => _settleRatio(),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  hintText: '9:16',
                                  hintStyle: TextStyle(
                                    fontSize: 14,
                                    color: palette.textMuted,
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          )
                        : lit
                        ? Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              _ratio.text,
                              style: text.copyWith(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(AppSettings s, List<ImageModel> ready, ImageEngine engine) {
    final palette = context.palette;
    final model = _modelIn(s, ready);
    final size = _sizeFor(model);
    final loras = engine.lorasFor(s);
    final job = engine.current;
    final progress = engine.progress;
    final muted = TextStyle(fontSize: 12.5, color: palette.textMuted);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Prompt presets',
                visualDensity: VisualDensity.compact,
                onPressed: _presets,
                icon: const Icon(Icons.bookmarks_outlined, size: 20),
              ),
              const SizedBox(width: 6),
              Text('Advanced', style: muted),
              const SizedBox(width: 4),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: _advanced,
                  onChanged: (v) {
                    setState(() => _advanced = v);
                    _remember(advanced: v);
                  },
                ),
              ),
            ],
          ),
          CallbackShortcuts(
            bindings: {
              for (final key in [
                const SingleActivator(LogicalKeyboardKey.enter, control: true),
                const SingleActivator(LogicalKeyboardKey.enter, meta: true),
              ])
                key: () {
                  if (_prompt.text.trim().isNotEmpty) _draw(ready);
                },
            },
            child: ResizableField(
              controller: _prompt,
              onChanged: (_) => setState(() {}),
              hintText: switch (model.prompting) {
                Prompting.tags => '1girl, silver hair, reading, cozy library',
                _ => 'A cozy library at night, warm lamplight, rain outside',
              },
            ),
          ),
          if (_advanced) ...[
            const SizedBox(height: 8),
            ResizableField(
              controller: _negative,
              maxLines: 3,
              hintText: 'What to leave out (negative prompt)',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                GlassSelect<String>(
                  label: 'Model',
                  value: model.id,
                  options: [for (final m in ready) GlassOption(m.id, m.name)],
                  onChanged: _pickModel,
                ),
                _number(
                  'Width',
                  _width,
                  '${size.width}',
                  onSettle: () => _settleSize(_width),
                ),
                IconButton(
                  tooltip: 'Swap width and height',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final w = _width.text.isEmpty
                        ? '${size.width}'
                        : _width.text;
                    _width.text = _height.text.isEmpty
                        ? '${size.height}'
                        : _height.text;
                    _height.text = w;
                    // 9:16 turns into 16:9 with the picture.
                    final r = ratioIn(_ratio.text);
                    if (r != null) {
                      _ratio.text = '${_plain(r.h)}:${_plain(r.w)}';
                    }
                    _widthLast = !_widthLast;
                  },
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                ),
                _number(
                  'Height',
                  _height,
                  '${size.height}',
                  onSettle: () => _settleSize(_height),
                ),
                _number('Steps', _steps, '${model.steps}'),
                _number('Guidance', _cfg, '${model.cfg}', decimal: true),
                _number('Seed', _seed, 'random', width: 110),
                GlassSelect<String>(
                  label: 'Sampler',
                  value: _sampler ?? '',
                  options: [
                    GlassOption(
                      '',
                      'Model\'s own (${SdRun.samplers[model.sampler] ?? model.sampler})',
                    ),
                    for (final e in SdRun.samplers.entries)
                      GlassOption(e.key, e.value),
                  ],
                  onChanged: (v) {
                    setState(() => _sampler = v.isEmpty ? null : v);
                    _saveChoices();
                  },
                ),
                GlassSelect<String>(
                  label: 'Scheduler',
                  value: _scheduler ?? '',
                  options: [
                    GlassOption(
                      '',
                      'Model\'s own (${SdRun.schedulers[model.scheduler] ?? 'Normal'})',
                    ),
                    for (final e in SdRun.schedulers.entries)
                      GlassOption(e.key, e.value),
                  ],
                  onChanged: (v) {
                    setState(() => _scheduler = v.isEmpty ? null : v);
                    _saveChoices();
                  },
                ),
                if (_width.text.isNotEmpty ||
                    _height.text.isNotEmpty ||
                    _ratio.text.isNotEmpty ||
                    _steps.text.isNotEmpty ||
                    _cfg.text.isNotEmpty ||
                    _seed.text.isNotEmpty ||
                    _sampler != null ||
                    _scheduler != null)
                  TextButton(
                    onPressed: _resetNumbers,
                    child: const Text('Reset'),
                  ),
              ],
            ),
            if (loras.isNotEmpty) ...[
              const SizedBox(height: 8),
              LoraSection(
                open: _lorasOpen,
                onToggle: () {
                  setState(() => _lorasOpen = !_lorasOpen);
                  _remember(lorasOpen: _lorasOpen);
                },
                loras: loras,
                picked: _loras,
                onChanged: (name, weight) {
                  setState(
                    () => weight == null
                        ? _loras.remove(name)
                        : _loras[name] = weight,
                  );
                  _scheduleSave();
                },
              ),
            ],
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              _shapePicker(model),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _advanced ? '' : model.name,
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilledButton.icon(
                onPressed: _prompt.text.trim().isEmpty
                    ? null
                    : () => _draw(ready),
                icon: const Icon(Icons.brush_rounded, size: 18),
                label: const Text('Draw'),
              ),
            ],
          ),
          if (job != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress == null || progress == 0 ? null : progress,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${engine.status ?? 'Drawing'}'
                    '${engine.downloads['engine'] == null ? '' : ' ${(engine.downloads['engine']! * 100).round()}%'}'
                    '${engine.waiting > 0 ? ' · ${engine.waiting} waiting' : ''}',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                ),
                TextButton(
                  onPressed: engine.cancelAll,
                  child: const Text('Stop'),
                ),
              ],
            ),
          ],
          if (_drawError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                _drawError!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
        ],
      ),
    );
  }

  /// A number typed into a glass box, matching the pickers beside it. A
  /// [size] settles on a multiple of 64 when the field is left.
  Widget _number(
    String label,
    TextEditingController c,
    String hint, {
    bool decimal = false,
    double width = 80,

    /// For sizes: called when the field is left or Enter is pressed, to
    /// settle on a multiple of 64 (and follow a ratio).
    VoidCallback? onSettle,
  }) {
    final size = onSettle != null;
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    OutlineInputBorder edge(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color),
    );
    final field = TextField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(decimal ? r'[\d.]' : r'\d')),
        if (size) LengthLimitingTextInputFormatter(4),
      ],
      onSubmitted: onSettle == null ? null : (_) => onSettle(),
      style: TextStyle(fontSize: 14, color: palette.text),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14, color: palette.textMuted),
        filled: true,
        fillColor: Colors.transparent,
        hoverColor: palette.tile,
        border: edge(palette.glassBorder),
        enabledBorder: edge(palette.glassBorder),
        focusedBorder: edge(accent.withValues(alpha: 0.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
        ),
        SizedBox(
          width: width,
          height: 36,
          child: onSettle != null
              ? Tooltip(
                  message:
                      'Any size from $_minSize to $_maxSize; it settles '
                      'on a multiple of 64',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Focus(
                    skipTraversal: true,
                    onFocusChange: (on) {
                      if (!on) onSettle();
                    },
                    child: field,
                  ),
                )
              : field,
        ),
      ],
    );
  }
}
