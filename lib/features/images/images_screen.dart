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
import '../../services/images/picture_info.dart';
import '../../services/images/sd_runtime.dart';
import '../../services/import/soulkyn_media.dart';
import '../../services/system/file_actions.dart';
import '../../theme/app_theme.dart';
import 'animate_dialog.dart';
import 'draw_panel.dart';
import 'picture_info_panel.dart';
import 'soulkyn_download_dialog.dart';

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
  bool _drawOpen = false;
  Future<List<File>>? _images;

  /// Why the last clip couldn't be made.
  String? _drawError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
                    if (s.companionFolder case final folder?)
                      DrawPanel(
                        folder: folder,
                        onDrawn: (_) {
                          if (mounted) _reloadImages();
                        },
                      ),
                  ],
                  if (_drawError != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      _drawError!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
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
                              onAnimate: _animate,
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
  await PictureInfo.deleteFor(file);
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

  /// What it was drawn with, when that was kept.
  PictureInfo? _info;
  bool _infoOpen = false;

  @override
  void initState() {
    super.initState();
    PictureInfo.read(widget.file).then((info) {
      if (mounted && info != null) setState(() => _info = info);
    });
  }

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
                    if (_info != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: light),
                        onPressed: () => setState(() => _infoOpen = !_infoOpen),
                        icon: Icon(
                          _infoOpen
                              ? Icons.info_rounded
                              : Icons.info_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('Info'),
                      ),
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
              if (_info case final info? when _infoOpen)
                Positioned(
                  top: 64,
                  right: 16,
                  bottom: 16,
                  width: 360,
                  child: PictureInfoPanel(
                    info: info,
                    onClose: () => setState(() => _infoOpen = false),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
