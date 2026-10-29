import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/folder_service.dart';
import '../../services/images/image_catalog.dart';
import '../../services/images/image_engine.dart';
import '../../services/images/sd_runtime.dart';
import '../../theme/app_theme.dart';
import 'resizable_field.dart';

/// Every picture in `<companion folder>/images/`, and a panel to draw one by
/// hand. Models, LoRAs and the switch live in Settings → Images.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key, this.onSettings});

  /// Opens Settings → Images.
  final VoidCallback? onSettings;

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  final _prompt = TextEditingController();
  final _negative = TextEditingController();
  final _steps = TextEditingController();
  final _cfg = TextEditingController();
  final _seed = TextEditingController();
  bool _drawOpen = false;
  bool _advanced = false;
  String _shape = 'square';
  String? _model;
  int? _width;
  int? _height;

  /// Set once the panel has picked up what it was left showing; filling the
  /// fields from the saved choices must not save them back.
  bool _loaded = false;
  bool _applying = false;
  Timer? _saveTimer;
  SettingsStore? _store;

  /// LoRAs picked in the advanced options, by name, with their weight.
  final _loras = <String, double>{};
  Future<List<File>>? _images;
  String? _drawError;

  static const _sizes = [512, 576, 640, 704, 768, 832, 896, 1024, 1216, 1536];

  @override
  void initState() {
    super.initState();
    _negative.addListener(_scheduleSave);
    for (final c in [_steps, _cfg, _seed]) {
      c.addListener(_numbersChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = AppScope.of(context).settings;
    _images ??= _listImages(
      AppScope.of(context).settings.value.companionFolder,
    );
    // The screen stays built while another tab is open; coming back, look
    // for pictures drawn (or added to the folder) meanwhile.
    final shown = TickerMode.valuesOf(context).enabled;
    if (shown && !_shown) {
      _images = _listImages(
        AppScope.of(context).settings.value.companionFolder,
      );
    }
    _shown = shown;
  }

  bool _shown = true;

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) _saveChoices();
    _saveTimer?.cancel();
    for (final c in [_prompt, _negative, _steps, _cfg, _seed]) {
      c.dispose();
    }
    super.dispose();
  }

  void _reloadImages() => setState(
    () => _images = _listImages(
      AppScope.of(context).settings.value.companionFolder,
    ),
  );

  static Future<List<File>> _listImages(String? root) async {
    if (root == null) return const [];
    final dir = CompanionFolder(root).images;
    if (!await dir.exists()) return const [];
    final files = await dir
        .list()
        .where(
          (e) =>
              e is File &&
              RegExp(
                r'\.(png|jpe?g|webp)$',
                caseSensitive: false,
              ).hasMatch(e.path),
        )
        .cast<File>()
        .toList();
    final stamps = {for (final f in files) f: await f.lastModified()};
    files.sort((a, b) => stamps[b]!.compareTo(stamps[a]!));
    return files;
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
    _shape = saved.shape;
    _model =
        (ready.where((m) => m.id == saved.model).firstOrNull ??
                ImageCatalog.defaultFor(s, ready)!)
            .id;
    _applyChoices(saved.perModel[_model] ?? const DrawChoices());
  }

  /// Puts [c] into the fields.
  void _applyChoices(DrawChoices c) {
    _applying = true;
    _width = c.width;
    _height = c.height;
    _steps.text = c.steps?.toString() ?? '';
    _cfg.text = c.cfg == null ? '' : '${c.cfg}';
    _seed.text = c.seed?.toString() ?? '';
    _negative.text = c.negative;
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
      width: _width,
      height: _height,
      steps: int.tryParse(_steps.text),
      cfg: double.tryParse(_cfg.text),
      seed: int.tryParse(_seed.text),
      negative: _negative.text,
    );
    final draw = store.value.draw;
    if ((draw.perModel[id] ?? const DrawChoices()) == now) return;
    unawaited(
      store.update(store.value.copyWith(draw: draw.withChoices(id, now))),
    );
  }

  /// Keeps the Advanced switch, the shape or the model.
  void _remember({bool? advanced, String? shape, String? model}) {
    final store = _store;
    if (store == null) return;
    final draw = store.value.draw;
    unawaited(
      store.update(
        store.value.copyWith(
          draw: draw.copyWith(advanced: advanced, shape: shape, model: model),
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
      _width = _height = null;
      _steps.clear();
      _cfg.clear();
      _seed.clear();
      _applying = false;
    });
    _saveChoices();
  }

  Future<void> _draw(List<ImageModel> ready) async {
    final services = AppScope.of(context);
    final s = services.settings.value;
    final folder = s.companionFolder;
    final prompt = _prompt.text.trim();
    if (folder == null || prompt.isEmpty || ready.isEmpty) return;
    final model = _modelIn(s, ready);
    final size = model.sizeFor(_shape);
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
                  for (final e in _loras.entries)
                    (name: e.key, weight: e.value),
                ],
                width: _width ?? size.width,
                height: _height ?? size.height,
                steps: int.tryParse(_steps.text)?.clamp(1, 150),
                cfg: double.tryParse(_cfg.text)?.clamp(0, 30).toDouble(),
                seed: int.tryParse(_seed.text),
              )
            : DrawRequest(model: model, prompt: prompt, shape: _shape),
        folder: folder,
        forChat: false,
      ),
    );
    try {
      await job.done;
      if (mounted) _reloadImages();
    } catch (e) {
      if (mounted) setState(() => _drawError = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final engine = services.imageEngine;
    return ListenableBuilder(
      listenable: Listenable.merge([services.settings, engine]),
      builder: (context, _) {
        final s = services.settings.value;
        final palette = context.palette;
        final on = s.imageEngine != ImageEngineChoice.off;
        final invoke = s.imageEngine == ImageEngineChoice.invoke;
        if (invoke && engine.invokeUrl != s.invokeUrl) {
          // First visit with Invoke: ask it what it has.
          engine.invokeUrl = s.invokeUrl;
          unawaited(engine.refreshInvoke(s));
        }
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
        final canDraw = on && ready.isNotEmpty;
        final titleStyle = Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600);
        // Slivers, so only the thumbnails in view are built and decoded,
        // not the whole gallery at once.
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              sliver: SliverList.list(
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Pictures', style: titleStyle)),
                      if (canDraw)
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              setState(() => _drawOpen = !_drawOpen),
                          icon: Icon(
                            _drawOpen
                                ? Icons.close_rounded
                                : Icons.brush_rounded,
                            size: 18,
                          ),
                          label: Text(_drawOpen ? 'Close' : 'Draw'),
                        ),
                      IconButton(
                        tooltip: 'Picture settings',
                        onPressed: widget.onSettings,
                        icon: const Icon(Icons.tune_rounded),
                      ),
                    ],
                  ),
                  if (!canDraw)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        invoke
                            ? 'Invoke isn\'t answering at ${s.invokeUrl}, or has no '
                                  'Stable Diffusion model. Check it in Settings → '
                                  'Images.'
                            : !SdInstaller.supported
                            ? 'Drawing isn\'t available for this computer yet.'
                            : !on
                            ? 'To let ${s.companionName} draw, turn it on in '
                                  'Settings → Images.'
                            : 'Download a picture model in Settings → Images to '
                                  'start drawing.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  if (canDraw && (_drawOpen || engine.current != null)) ...[
                    const SizedBox(height: 12),
                    _drawPanel(s, ready, engine),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
            FutureBuilder<List<File>>(
              future: _images,
              builder: (context, snap) {
                final files = snap.data ?? const [];
                if (files.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 60),
                      child: Center(
                        child: Text(
                          'No pictures yet.',
                          style: TextStyle(color: palette.textMuted),
                        ),
                      ),
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                        ),
                    itemCount: files.length,
                    itemBuilder: (context, i) => InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => showPicture(context, files[i]),
                      child: Hero(
                        tag: files[i].path,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.file(
                            files[i],
                            fit: BoxFit.cover,
                            cacheWidth: 440,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _drawPanel(AppSettings s, List<ImageModel> ready, ImageEngine engine) {
    final palette = context.palette;
    final model = _modelIn(s, ready);
    final size = model.sizeFor(_shape);
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
                  'Draw something yourself',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
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
              spacing: 14,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _labelled(
                  'Model',
                  DropdownButton<String>(
                    value: model.id,
                    items: [
                      for (final m in ready)
                        DropdownMenuItem(value: m.id, child: Text(m.name)),
                    ],
                    onChanged: (v) => _pickModel(v!),
                  ),
                ),
                _labelled(
                  'Width',
                  _sizePicker(_width ?? size.width, (v) {
                    setState(() => _width = v);
                    _scheduleSave();
                  }),
                ),
                IconButton(
                  tooltip: 'Swap width and height',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() {
                      final w = _width ?? size.width;
                      _width = _height ?? size.height;
                      _height = w;
                    });
                    _scheduleSave();
                  },
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                ),
                _labelled(
                  'Height',
                  _sizePicker(_height ?? size.height, (v) {
                    setState(() => _height = v);
                    _scheduleSave();
                  }),
                ),
                _number('Steps', _steps, '${model.steps}'),
                _number('Guidance', _cfg, '${model.cfg}', decimal: true),
                _number('Seed', _seed, 'random', width: 110),
                if (_width != null ||
                    _height != null ||
                    _steps.text.isNotEmpty ||
                    _cfg.text.isNotEmpty ||
                    _seed.text.isNotEmpty)
                  TextButton(
                    onPressed: _resetNumbers,
                    child: const Text('Reset'),
                  ),
              ],
            ),
            if (loras.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('LoRAs', style: muted),
              for (final l in loras)
                Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _loras.containsKey(l.name),
                          onChanged: (v) => setState(
                            () => v == true
                                ? _loras[l.name] = 0.8
                                : _loras.remove(l.name),
                          ),
                        ),
                        Expanded(
                          child: Tooltip(
                            message: l.note,
                            child: Text(
                              l.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 200,
                          child: Slider(
                            value: _loras[l.name] ?? 0.8,
                            min: -1,
                            max: 2,
                            divisions: 30,
                            onChanged: _loras.containsKey(l.name)
                                ? (v) => setState(() => _loras[l.name] = v)
                                : null,
                          ),
                        ),
                        SizedBox(
                          width: 34,
                          child: Text(
                            (_loras[l.name] ?? 0.8).toStringAsFixed(1),
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (!_advanced) ...[
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: 'square',
                      icon: Icon(Icons.crop_square_rounded),
                      tooltip: 'Square',
                    ),
                    ButtonSegment(
                      value: 'portrait',
                      icon: Icon(Icons.crop_portrait_rounded),
                      tooltip: 'Portrait',
                    ),
                    ButtonSegment(
                      value: 'landscape',
                      icon: Icon(Icons.crop_landscape_rounded),
                      tooltip: 'Landscape',
                    ),
                  ],
                  selected: {_shape},
                  onSelectionChanged: (v) {
                    setState(() => _shape = v.single);
                    _remember(shape: v.single);
                  },
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    model.name,
                    style: muted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
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

  Widget _labelled(String label, Widget child) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(fontSize: 11.5, color: context.palette.textMuted),
      ),
      child,
    ],
  );

  Widget _sizePicker(int value, ValueChanged<int> onChanged) =>
      DropdownButton<int>(
        value: value,
        items: [
          for (final v in {..._sizes, value}.toList()..sort())
            DropdownMenuItem(value: v, child: Text('$v')),
        ],
        onChanged: (v) => onChanged(v!),
      );

  Widget _number(
    String label,
    TextEditingController c,
    String hint, {
    bool decimal = false,
    double width = 80,
  }) => _labelled(
    label,
    SizedBox(
      width: width,
      child: TextField(
        controller: c,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(decimal ? r'[\d.]' : r'\d')),
        ],
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          // Underlined like the dropdowns beside it.
          filled: false,
          border: const UnderlineInputBorder(),
          enabledBorder: const UnderlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    ),
  );
}

/// Shows [file] over the window: scroll or pinch to zoom, drag to look
/// around, and "Show file" opens it in the computer's own picture viewer.
/// Escape, the close button or a click beside the picture closes it.
Future<void> showPicture(BuildContext context, File file) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (context) => _PictureViewer(file: file),
);

class _PictureViewer extends StatefulWidget {
  const _PictureViewer({required this.file});
  final File file;

  @override
  State<_PictureViewer> createState() => _PictureViewerState();
}

class _PictureViewerState extends State<_PictureViewer> {
  final _zoom = TransformationController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _scale(double by) {
    final size = MediaQuery.sizeOf(context);
    final centre = Offset(size.width / 2, size.height / 2);
    final current = _zoom.value.getMaxScaleOnAxis();
    final next = (current * by).clamp(1.0, 8.0);
    final f = next / current;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-centre.dx, -centre.dy, 0, 1)
      ..multiply(_zoom.value);
  }

  @override
  Widget build(BuildContext context) {
    const light = Colors.white;
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.pop(context),
          const SingleActivator(LogicalKeyboardKey.equal): () => _scale(1.25),
          const SingleActivator(LogicalKeyboardKey.minus): () => _scale(0.8),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              // A click beside the picture closes it, like clicking
              // outside any other window; one on the picture doesn't.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.pop(context),
                  child: InteractiveViewer(
                    transformationController: _zoom,
                    minScale: 1,
                    maxScale: 8,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
                        child: GestureDetector(
                          onTap: () {},
                          onDoubleTap: () =>
                              _zoom.value.getMaxScaleOnAxis() > 1.01
                              ? _zoom.value = Matrix4.identity()
                              : _scale(2.5),
                          child: Hero(
                            tag: widget.file.path,
                            child: Image.file(widget.file),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 20,
                right: 12,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.basename(widget.file.path),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: light),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zoom out',
                      color: light,
                      onPressed: () => _scale(0.8),
                      icon: const Icon(Icons.zoom_out_rounded),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      color: light,
                      onPressed: () => _scale(1.25),
                      icon: const Icon(Icons.zoom_in_rounded),
                    ),
                    IconButton(
                      tooltip: 'Fit',
                      color: light,
                      onPressed: () => _zoom.value = Matrix4.identity(),
                      icon: const Icon(Icons.fit_screen_rounded),
                    ),
                    const SizedBox(width: 6),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: light),
                      onPressed: () => launchUrl(Uri.file(widget.file.path)),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Show file'),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      color: light,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
