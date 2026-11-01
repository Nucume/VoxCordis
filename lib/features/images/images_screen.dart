import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/avatar_video.dart';
import '../../services/folder_service.dart';
import '../../services/images/image_catalog.dart';
import '../../services/images/image_engine.dart';
import '../../services/images/sd_runtime.dart';
import '../../services/import/soulkyn_media.dart';
import '../../services/updater.dart' show videoGenEnabled;
import '../../services/system/file_actions.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import 'animate_dialog.dart';
import 'lora_grid.dart';
import 'soulkyn_download_dialog.dart';
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
  final _width = TextEditingController();
  final _height = TextEditingController();
  bool _drawOpen = false;
  bool _advanced = false;
  String _shape = 'square';
  String? _model;

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

  @override
  void initState() {
    super.initState();
    _negative.addListener(_scheduleSave);
    for (final c in [_steps, _cfg, _seed, _width, _height]) {
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
    for (final c in [
      _prompt,
      _negative,
      _steps,
      _cfg,
      _seed,
      _width,
      _height,
    ]) {
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
                r'\.(png|jpe?g|webp|mp4|webm)$',
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
    _width.text = c.width?.toString() ?? '';
    _height.text = c.height?.toString() ?? '';
    _steps.text = c.steps?.toString() ?? '';
    _cfg.text = c.cfg == null ? '' : '${c.cfg}';
    _seed.text = c.seed?.toString() ?? '';
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
      width: _sizeIn(_width),
      height: _sizeIn(_height),
      steps: int.tryParse(_steps.text),
      cfg: double.tryParse(_cfg.text),
      seed: int.tryParse(_seed.text),
      negative: _negative.text,
      loras: {..._loras},
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
      _width.clear();
      _height.clear();
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

  /// Asks what should happen, then queues a clip made from [picture].
  Future<void> _animate(File picture) async {
    final services = AppScope.of(context);
    final s = services.settings.value;
    final models = ImageCatalog.availableVideo(ImageCatalog.videoFor(s));
    final messenger = ScaffoldMessenger.of(context);
    if (s.imageEngine != ImageEngineChoice.builtIn || models.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            s.imageEngine != ImageEngineChoice.builtIn
                ? 'Clips need the built-in drawing (Settings → Images).'
                : 'Download ${ImageCatalog.videoModels.first.name} in '
                      'Settings → Images first.',
          ),
        ),
      );
      return;
    }
    final gpu = await services.runtime.gpu;
    if (!mounted) return;
    final choice = await showDialog<AnimateChoice>(
      context: context,
      builder: (context) => AnimateDialog(
        models: models,
        picture: picture,
        gpu: gpu,
        writePrompt: (idea, model, seconds) => services.writeClipPrompt(
          idea,
          detailed: model.detailedPrompt,
          seconds: seconds,
          model: model.name,
          chars: model.promptChars,
          limit: model.promptMax,
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final folder = s.companionFolder;
    if (folder == null) return;
    final job = await services.imageEngine.animate(
      picture,
      folder: folder,
      prompt: choice.prompt,
      seconds: choice.seconds,
      modelId: choice.modelId,
    );
    if (job == null) return;
    setState(() => _drawError = null);
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
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: s.companionFolder == null
                            ? null
                            : () async {
                                final folder = s.companionFolder!;
                                final added = await showSoulkynDownload(
                                  context,
                                  into: CompanionFolder(folder).images,
                                  folder: folder,
                                );
                                if (added && mounted) _reloadImages();
                              },
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: const Text('Download all Images & Videos'),
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
                    itemBuilder: (context, i) => _isVideo(files[i])
                        ? _VideoTile(file: files[i], onDeleted: _reloadImages)
                        : InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => showPicture(
                              context,
                              files[i],
                              onAnimate: videoGenEnabled
                                  ? (f) => _animate(f)
                                  : null,
                              onDeleted: _reloadImages,
                            ),
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
                _number('Width', _width, '${size.width}', size: true),
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
                  },
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                ),
                _number('Height', _height, '${size.height}', size: true),
                _number('Steps', _steps, '${model.steps}'),
                _number('Guidance', _cfg, '${model.cfg}', decimal: true),
                _number('Seed', _seed, 'random', width: 110),
                if (_width.text.isNotEmpty ||
                    _height.text.isNotEmpty ||
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
              const SizedBox(height: 6),
              LoraGrid(
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

  /// A number typed into a glass box, matching the pickers beside it. A
  /// [size] settles on a multiple of 64 when the field is left.
  Widget _number(
    String label,
    TextEditingController c,
    String hint, {
    bool decimal = false,
    bool size = false,
    double width = 80,
  }) {
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
      onSubmitted: size ? (_) => _settle(c) : null,
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
          child: size
              ? Tooltip(
                  message:
                      'Any size from $_minSize to $_maxSize; it settles '
                      'on a multiple of 64',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Focus(
                    skipTraversal: true,
                    onFocusChange: (on) {
                      if (!on) _settle(c);
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

bool _isVideo(File f) => SoulkynMediaDownload.videoExtensions.contains(
  p.extension(f.path).replaceFirst('.', '').toLowerCase(),
);

/// A video in the gallery: its poster when one was saved, with a play
/// sign. It plays in the app, or in the computer's own video player when
/// libmpv is missing.
class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.file, this.onDeleted});
  final File file;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final poster = SoulkynMediaDownload.posterFor(file);
    return Tooltip(
      message: 'Play ${p.basename(file.path)}',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => AvatarVideo.available
            ? showDialog<void>(
                context: context,
                barrierColor: Colors.black87,
                builder: (_) => _VideoViewer(file: file, onDeleted: onDeleted),
              )
            : launchUrl(Uri.file(file.path)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (poster != null)
                Image.file(poster, fit: BoxFit.cover, cacheWidth: 440)
              else
                const ColoredBox(color: Colors.black54),
              const Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
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

/// Plays a gallery video with sound and controls, looping.
class _VideoViewer extends StatefulWidget {
  const _VideoViewer({required this.file, this.onDeleted});
  final File file;
  final VoidCallback? onDeleted;

  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  final _subs = <StreamSubscription<Object?>>[];
  SettingsStore? _store;
  Timer? _saveVolume;
  double? _aspect;

  @override
  void initState() {
    super.initState();
    unawaited(_player.setPlaylistMode(PlaylistMode.single));
    _subs
      ..add(_player.stream.width.listen((_) => _sized()))
      ..add(_player.stream.height.listen((_) => _sized()))
      ..add(_player.stream.volume.listen(_volumeChanged));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_store != null) return;
    final store = _store = AppScope.of(context).settings;
    // The volume it was left at, every time.
    unawaited(() async {
      await _player.setVolume(store.value.videoVolume);
      await _player.open(Media(widget.file.uri.toString()));
    }());
  }

  /// Fits the video to its own shape, so a click beside it closes the
  /// viewer, as with pictures.
  void _sized() {
    final w = _player.state.width, h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0 || !mounted) return;
    setState(() => _aspect = w / h);
  }

  void _volumeChanged(double v) {
    final store = _store;
    if (store == null || (v - store.value.videoVolume).abs() < 0.5) return;
    _saveVolume?.cancel();
    _saveVolume = Timer(const Duration(milliseconds: 400), () {
      unawaited(
        store.update(store.value.copyWith(videoVolume: v.clamp(0, 100))),
      );
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    if (_saveVolume?.isActive ?? false) {
      _saveVolume!.cancel();
      final store = _store;
      final v = _player.state.volume;
      if (store != null) {
        unawaited(
          store.update(store.value.copyWith(videoVolume: v.clamp(0, 100))),
        );
      }
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const light = Colors.white;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
                  child: Center(
                    // Built from the start: the player only reports its
                    // size once the video widget exists, so waiting for
                    // the size before building it showed nothing at all.
                    child: AspectRatio(
                      aspectRatio: _aspect ?? 16 / 9,
                      child: GestureDetector(
                        onTap: () {},
                        child: Video(
                          controller: _video,
                          fill: Colors.transparent,
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
                  ..._fileActions(
                    context,
                    widget.file,
                    onDeleted: widget.onDeleted,
                    // Let go of the file first, or Windows won't move it.
                    beforeDelete: _player.stop,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Show file", "Show in folder", Delete (when the gallery can drop the
/// file afterwards) and Close, for the top bar of the picture and video
/// viewers.
List<Widget> _fileActions(
  BuildContext context,
  File file, {
  VoidCallback? onDeleted,
  Future<void> Function()? beforeDelete,
}) {
  const light = Colors.white;
  return [
    TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: light),
      onPressed: () => launchUrl(Uri.file(file.path)),
      icon: const Icon(Icons.open_in_new_rounded, size: 18),
      label: const Text('Show file'),
    ),
    IconButton(
      tooltip: 'Show in folder',
      color: light,
      onPressed: () => FileActions.showInFolder(file),
      icon: const Icon(Icons.folder_open_rounded),
    ),
    if (onDeleted != null)
      IconButton(
        tooltip: 'Delete',
        color: light,
        onPressed: () async {
          if (!await _confirmDelete(context, file)) return;
          await beforeDelete?.call();
          final error = await _delete(file);
          if (!context.mounted) return;
          if (error != null) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text('Couldn\'t delete it: $error')),
            );
            return;
          }
          Navigator.pop(context);
          onDeleted();
        },
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    IconButton(
      tooltip: 'Close',
      color: light,
      onPressed: () => Navigator.pop(context),
      icon: const Icon(Icons.close_rounded),
    ),
  ];
}

Future<bool> _confirmDelete(BuildContext context, File file) async {
  final video = _isVideo(file);
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(video ? 'Delete this video?' : 'Delete this picture?'),
          content: Text(
            '${p.basename(file.path)} goes to the computer\'s trash, so you '
            'can still get it back from there.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;
}

/// Trashes [file], and a video's poster with it. The reason when it
/// couldn't, else null.
Future<String?> _delete(File file) async {
  final poster = _isVideo(file) ? SoulkynMediaDownload.posterFor(file) : null;
  try {
    await FileActions.trash(file);
  } on FileSystemException catch (e) {
    return e.osError?.message ?? e.message;
  }
  if (poster != null) {
    try {
      await poster.delete();
    } on FileSystemException {
      // Only a still for the tile.
    }
  }
  return null;
}

/// Shows [file] over the window: scroll or pinch to zoom, drag to look
/// around, and "Show file" opens it in the computer's own picture viewer.
/// Escape, the close button or a click beside the picture closes it.
///
/// With [onAnimate], a picture also offers to become a clip; with
/// [onDeleted], it can be deleted, and that is called after.
Future<void> showPicture(
  BuildContext context,
  File file, {
  void Function(File picture)? onAnimate,
  VoidCallback? onDeleted,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (context) =>
      _PictureViewer(file: file, onAnimate: onAnimate, onDeleted: onDeleted),
);

class _PictureViewer extends StatefulWidget {
  const _PictureViewer({required this.file, this.onAnimate, this.onDeleted});
  final File file;
  final void Function(File picture)? onAnimate;
  final VoidCallback? onDeleted;

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
                    if (widget.onAnimate != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: light),
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onAnimate!(widget.file);
                        },
                        icon: const Icon(
                          Icons.movie_creation_outlined,
                          size: 18,
                        ),
                        label: const Text('Animate'),
                      ),
                    ..._fileActions(
                      context,
                      widget.file,
                      onDeleted: widget.onDeleted,
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
