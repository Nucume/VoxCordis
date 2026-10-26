import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/folder_service.dart';
import '../../services/llm_client.dart';
import '../../services/llm_providers.dart';
import '../../services/runtime/gpu_info.dart';
import '../../services/runtime/model_catalog.dart';
import '../../services/sight.dart';
import '../../theme/app_theme.dart';

/// Chooses the companion's brain: a model for the built-in runtime (download
/// one or attach a .gguf), or a server-hosted OpenAI-compatible API: a
/// cloud provider from [LlmProvider] or any address.
/// Used by Settings and by first-run setup.
class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.showModelsFolder = true,
  });

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  /// Setup chooses the folder on its Home step, so it hides the row here.
  final bool showModelsFolder;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  late final _endpoint = TextEditingController(text: widget.value.llmEndpoint);
  late final _model = TextEditingController(text: widget.value.llmModel);
  late final _apiKey = TextEditingController(text: widget.value.llmApiKey);
  List<String> _remoteModels = const [];

  /// What was typed for each provider the human switched away from.
  final _typed =
      <LlmProvider, ({String endpoint, String model, String apiKey})>{};
  Set<String> _downloaded = {};
  GpuInfo _gpu = GpuInfo.unknown;

  /// The memory span follows the model and card until the user picks one.
  bool _spanTouched = false;
  bool _spanPicked = false;

  // Each mode keeps its own error, so switching back and forth keeps it.
  String? _builtInError;
  String? _serverError;

  AppSettings get _v => widget.value;

  @override
  void initState() {
    super.initState();
    for (final c in [_endpoint, _model, _apiKey]) {
      c.addListener(_pushExternal);
    }
    if (_v.llmMode == LlmMode.external && _provider == LlmProvider.openRouter) {
      _fetchRemoteModels();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scanDownloaded();
    AppScope.of(context).runtime.gpu.then((g) {
      if (!mounted) return;
      setState(() => _gpu = g);
      // Setup starts without a model: size the span for the recommendation.
      if (_v.modelPath == null) widget.onChanged(_fitSpan(_v));
    });
  }

  @override
  void dispose() {
    for (final c in [_endpoint, _model, _apiKey]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scanDownloaded() async {
    final files = await ModelCatalog.downloaded(ModelCatalog.dirFor(_v));
    if (!mounted) return;
    setState(() => _downloaded = {for (final f in files) f.path});
  }

  void _pushExternal() {
    if (_v.llmMode != LlmMode.external) return;
    widget.onChanged(
      _v.copyWith(
        llmEndpoint: _endpoint.text.trim(),
        llmModel: _model.text.trim(),
        llmApiKey: _apiKey.text.trim(),
      ),
    );
  }

  /// [s] with the longest memory span its model fits on the card, unless
  /// the user chose a span themselves. On the processor it stays Normal.
  AppSettings _fitSpan(AppSettings s) {
    if (_spanTouched || s.llmMode != LlmMode.builtIn) return s;
    final base =
        ModelCatalog.needGb(s.copyWith(contextSize: 8192)) ??
        ModelCatalog.recommendFor(_gpu)?.minMemoryGb.toDouble();
    final ctx = base == null || !s.useGpu
        ? 8192
        : suggestContextSize(baseGb: base, cardGb: _gpu.memoryGb);
    _spanPicked = _gpu.memoryGb != null && s.useGpu;
    return s.copyWith(contextSize: ctx);
  }

  Future<void> _download(CatalogModel m) async {
    setState(() => _builtInError = null);
    if (m.huge && !await _confirmHuge(m)) return;
    if (!mounted) return;
    try {
      final path = await AppScope.of(
        context,
      ).runtime.download(m, ModelCatalog.dirFor(_v));
      await _scanDownloaded();
      widget.onChanged(_fitSpan(_v.copyWith(modelPath: path)));
    } catch (e) {
      if (mounted) setState(() => _builtInError = '${m.name}: $e');
    }
  }

  /// Red warning before a download far beyond a normal PC.
  Future<bool> _confirmHuge(CatalogModel m) async {
    final danger = Theme.of(context).colorScheme.error;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.dangerous_rounded, color: danger, size: 36),
        title: Text('${m.name} is HUGE', style: TextStyle(color: danger)),
        content: SizedBox(
          width: 440,
          child: Text(
            'This is a ${m.sizeGb.round()} GB download. Make sure that much '
            'disk space is free, and expect it to take hours.\n\n'
            'It needs about ${m.minMemoryGb} GB of graphics and main memory '
            'together. Even a 32 GB card runs most of it on the main '
            'processor, so replies are slow, and on a normal PC it will not '
            'load at all.\n\n'
            'Its refusals have been removed, so it will answer requests '
            'other models turn down.',
            style: const TextStyle(height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: danger),
            child: Text('Download ${m.sizeGb.round()} GB'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  Future<void> _attach() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'GGUF model', extensions: ['gguf']),
      ],
    );
    if (file == null) return;
    // Large files stay where they are; the app only remembers the path.
    // A vision file lying next to it comes along, so the model can see.
    final mmproj = ModelCatalog.mmprojBeside(file.path);
    widget.onChanged(
      _fitSpan(
        mmproj == null
            ? _v.copyWith(modelPath: file.path, clearMmproj: true)
            : _v.copyWith(modelPath: file.path, mmprojPath: mmproj),
      ),
    );
  }

  /// Moves every downloaded model to a folder the user picks. The runtime
  /// stops first, since a loaded model can't move on Windows.
  Future<void> _moveModels() async {
    final services = AppScope.of(context);
    final runtime = services.runtime;
    if (runtime.downloads.isNotEmpty) {
      setState(
        () => _builtInError =
            'Wait for the download to finish, then move the models.',
      );
      return;
    }
    final from = ModelCatalog.dirFor(_v);
    final path = await getDirectoryPath(
      initialDirectory: await from.exists() ? from.path : null,
      confirmButtonText: 'Move models here',
    );
    if (path == null || p.equals(path, from.path) || !mounted) return;
    final to = Directory(path);
    final status = ValueNotifier('Stopping the model…');
    setState(() => _builtInError = null);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Moving models'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(borderRadius: BorderRadius.circular(4)),
                const SizedBox(height: 10),
                ValueListenableBuilder(
                  valueListenable: status,
                  builder: (context, text, _) => Text(
                    text,
                    style: TextStyle(color: context.palette.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      await runtime.stopAll();
      await ModelCatalog.moveFolder(
        from,
        to,
        onFile: (name, i, count) =>
            status.value = 'Moving $name (${i + 1} of $count)',
      );
      // Saved right away: the files have moved, whatever happens to the
      // rest of this page.
      final stored = services.settings.value;
      await services.settings.update(
        stored.copyWith(
          modelsFolder: to.path,
          modelPath: ModelCatalog.movedPath(stored.modelPath, from, to),
        ),
      );
      widget.onChanged(
        _v.copyWith(
          modelsFolder: to.path,
          modelPath: ModelCatalog.movedPath(_v.modelPath, from, to),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _builtInError = 'Could not move models: $e');
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      status.dispose();
    }
    if (mounted) await _scanDownloaded();
  }

  Future<void> _fetchRemoteModels() async {
    final provider = _provider;
    if (_apiKey.text.trim().isEmpty &&
        provider != LlmProvider.custom &&
        provider != LlmProvider.openRouter) {
      setState(
        () => _serverError =
            'Paste your ${provider.label} API key first, then fetch.',
      );
      return;
    }
    setState(() => _serverError = null);
    try {
      final models = await LlmClient(
        baseUrl: _endpoint.text.trim(),
        model: '',
        apiKey: _apiKey.text.trim(),
      ).listModels();
      if (!mounted || _provider != provider) return;
      setState(() => _remoteModels = models..sort());
    } catch (e) {
      if (!mounted || _provider != provider) return;
      setState(
        () => _serverError = '$e'.contains('HTTP 401')
            ? '${provider.label} did not accept this API key.'
            : '$e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = AppScope.of(context).runtime;
    final builtIn = _v.llmMode == LlmMode.builtIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<LlmMode>(
            segments: const [
              ButtonSegment(
                value: LlmMode.builtIn,
                icon: Icon(Icons.memory_rounded),
                label: Text('Built-in (recommended)'),
              ),
              ButtonSegment(
                value: LlmMode.external,
                icon: Icon(Icons.dns_outlined),
                label: Text('Server-hosted'),
              ),
            ],
            selected: {_v.llmMode},
            onSelectionChanged: (s) =>
                widget.onChanged(_v.copyWith(llmMode: s.single)),
          ),
        ),
        const SizedBox(height: 18),
        if (builtIn)
          ListenableBuilder(
            listenable: runtime,
            builder: (context, _) => _builtIn(runtime.downloads),
          )
        else
          ..._external(),
        if ((builtIn ? _builtInError : _serverError) case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _builtIn(Map<String, double?> downloads) {
    final runtime = AppScope.of(context).runtime;
    final modelsDir = ModelCatalog.dirFor(_v);
    final current = _v.modelPath;
    final catalogFiles = {
      for (final m in ModelCatalog.models)
        ModelCatalog.fileFor(modelsDir, m).path,
    };
    final attached = current != null && !catalogFiles.contains(current)
        ? current
        : null;
    final recommended = ModelCatalog.recommendFor(_gpu);
    final mem = _gpu.memoryGb;

    String? tooBig(double needGb) => _v.useGpu && mem != null && needGb > mem
        ? 'Needs about ${needGb.round()} GB; your card has ${mem.round()} GB. '
              'It will run, but slowly.'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'VoxCordis runs the model itself, on this computer. Pick one to '
          'download, or attach a .gguf you already have.',
          style: TextStyle(color: context.palette.textMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        _GpuBanner(gpu: _gpu, recommended: recommended),
        const SizedBox(height: 8),
        // The recommended model first.
        for (final m in [
          ?recommended,
          ...ModelCatalog.models.where((m) => m != recommended),
        ])
          _ModelCard(
            title: m.name,
            subtitle:
                '${m.blurb}\n${m.sizeGb.toStringAsFixed(1)} GB download · '
                'about ${m.minMemoryGb} GB of graphics memory',
            uncensored: m.uncensored,
            sees: m.canSee,
            danger: m.huge
                ? 'Huge: ${m.sizeGb.round()} GB on disk and about '
                      '${m.minMemoryGb} GB of memory. Workstations only.'
                : null,
            warning: m.huge
                ? null
                : tooBig(
                    estimateNeedGb(
                      baseGb: m.minMemoryGb.toDouble(),
                      contextSize: _v.contextSize,
                    ),
                  ),
            recommended: m == recommended,
            selected: current == ModelCatalog.fileFor(modelsDir, m).path,
            downloaded: _downloaded.contains(
              ModelCatalog.fileFor(modelsDir, m).path,
            ),
            downloading: downloads.containsKey(m.id),
            progress: downloads[m.id],
            onDownload: () => _download(m),
            onCancel: () => runtime.cancelDownload(m.id),
            onUse: () => widget.onChanged(
              _fitSpan(
                _v.copyWith(modelPath: ModelCatalog.fileFor(modelsDir, m).path),
              ),
            ),
          ),
        if (attached != null)
          _ModelCard(
            title: p.basename(attached),
            subtitle: File(attached).existsSync()
                ? attached
                : 'File not found: $attached',
            warning: switch (ModelCatalog.needGb(_v)) {
              final need? => tooBig(need),
              null => null,
            },
            selected: true,
            downloaded: true,
            downloading: false,
            onUse: () {},
          ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _attach,
            icon: const Icon(Icons.attach_file_rounded),
            label: const Text('Attach a .gguf file'),
          ),
        ),
        if (widget.showModelsFolder) ...[
          const SizedBox(height: 14),
          _ModelsFolderRow(
            path: modelsDir.path,
            onOpen: () => launchUrl(Uri.directory(modelsDir.path)),
            onMove: _moveModels,
          ),
        ],
        const SizedBox(height: 22),
        Wrap(
          spacing: 28,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: _v.useGpu,
                  onChanged: (g) =>
                      widget.onChanged(_fitSpan(_v.copyWith(useGpu: g))),
                ),
                const SizedBox(width: 8),
                const Text('Use my graphics card'),
                const SizedBox(width: 6),
                InfoIcon(
                  message: _v.useGpu
                      ? 'The model runs on your graphics card, which is many '
                            'times faster than the main processor.\n\n'
                            'While VoxCordis is open the model stays in '
                            'graphics memory, so games and other GPU-heavy '
                            'apps will run much worse. Turn on "Free the '
                            'graphics card when I\'m not chatting", or close '
                            'VoxCordis, before gaming.'
                      : 'Off: the model runs on the main processor only. '
                            'Nothing else on your graphics card is affected, '
                            'but replies come much more slowly.',
                ),
              ],
            ),
            if (_v.useGpu)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: _v.freeGpuWhenIdle,
                    onChanged: (on) =>
                        widget.onChanged(_v.copyWith(freeGpuWhenIdle: on)),
                  ),
                  const SizedBox(width: 8),
                  const Text('Free the graphics card when I\'m not chatting'),
                  const SizedBox(width: 6),
                  const InfoIcon(
                    message:
                        'For gaming with VoxCordis open: after a minute '
                        'without typing, the model (and Eyes) leave graphics '
                        'memory. Typing loads the model again, which takes '
                        'from a few seconds to a minute, so the first reply '
                        'after a break can be slower.',
                  ),
                ],
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownMenu<int>(
                  // Rebuilt when the span is picked for the user.
                  key: ValueKey(_v.contextSize),
                  initialSelection: _v.contextSize,
                  label: const Text('Memory span'),
                  helperText: _spanPicked ? 'Fits your graphics card' : null,
                  width: 190,
                  onSelected: (c) {
                    if (c != null) {
                      _spanTouched = true;
                      _spanPicked = false;
                      widget.onChanged(_v.copyWith(contextSize: c));
                    }
                  },
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: 4096, label: 'Short (4k)'),
                    DropdownMenuEntry(value: 8192, label: 'Normal (8k)'),
                    DropdownMenuEntry(value: 16384, label: 'Long (16k)'),
                    DropdownMenuEntry(value: 32768, label: 'Very long (32k)'),
                  ],
                ),
                const SizedBox(width: 8),
                const InfoIcon(
                  message:
                      'How much of the current conversation your companion '
                      'can keep in mind at once. Normal is about 6,000 words.'
                      '\n\nLonger spans remember more of a long chat, but '
                      'need more graphics memory and answer a bit slower. '
                      'Saved memories (the Memory tab) are separate and '
                      'always available.\n\nVoxCordis picks the longest '
                      'span your graphics card fits with the chosen model.',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  LlmProvider get _provider => LlmProvider.forEndpoint(_endpoint.text);

  /// Switches the server to [to], keeping what was typed for the one left
  /// behind, so trying another provider and coming back loses nothing.
  void _pickProvider(LlmProvider to) {
    final from = _provider;
    if (to == from) return;
    _typed[from] = (
      endpoint: _endpoint.text,
      model: _model.text,
      apiKey: _apiKey.text,
    );
    final back = _typed[to];
    setState(() {
      _remoteModels = const [];
      _serverError = null;
    });
    _endpoint.text = back?.endpoint ?? to.endpoint;
    _model.text = back?.model ?? to.suggestedModels.firstOrNull ?? '';
    _apiKey.text = back?.apiKey ?? '';
    // OpenRouter lists its models without a key.
    if (to == LlmProvider.openRouter) _fetchRemoteModels();
  }

  List<Widget> _external() {
    final provider = _provider;
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);
    final custom = provider == LlmProvider.custom;
    final models = _remoteModels.isNotEmpty
        ? _remoteModels
        : provider.suggestedModels;
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in LlmProvider.values)
            ChoiceChip(
              label: Text(p.label),
              selected: p == provider,
              onSelected: (_) => _pickProvider(p),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text(provider.blurb, style: muted),
      if (!custom) ...[
        const SizedBox(height: 4),
        Text(
          'Everything your companion reads is sent to ${provider.label}, and '
          'its usage rules apply: your messages, the pictures and files you '
          'share, and the memories and notes in its prompt. Each message '
          'costs a little from your ${provider.label} credit.',
          style: muted,
        ),
      ] else if (Sight.picturesLeave(_v)) ...[
        const SizedBox(height: 4),
        Text(
          'This server isn\'t on your computer or home network: your '
          'messages, the pictures and files you share, and the memories and '
          'notes in the prompt are sent to it.',
          style: muted,
        ),
      ],
      if (custom)
        _field(
          _endpoint,
          'Server address',
          hint: 'http://localhost:11434/v1 (Ollama), :1234/v1 (LM Studio)',
        ),
      _field(
        _apiKey,
        custom ? 'API key (only for remote servers)' : 'API key',
        obscure: true,
      ),
      if (!custom)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(provider.keyUrl)),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text('Get an API key from ${provider.label}'),
          ),
        ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: models.isEmpty
                ? _field(_model, 'Model')
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: DropdownMenu<String>(
                      key: ValueKey(models),
                      controller: _model,
                      expandedInsets: EdgeInsets.zero,
                      label: const Text('Model'),
                      enableFilter: models.length > 12,
                      menuHeight: 360,
                      dropdownMenuEntries: [
                        for (final m in models)
                          DropdownMenuEntry(value: m, label: m),
                      ],
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 170,
            child: OutlinedButton(
              onPressed: _fetchRemoteModels,
              child: const Text('Fetch models'),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: TextField(
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

/// Asks before finishing when the chosen model won't fit the graphics card.
/// Returns true to go ahead.
Future<bool> confirmModelFits(BuildContext context, AppSettings s) async {
  if (s.llmMode != LlmMode.builtIn || !s.useGpu) return true;
  final runtime = AppScope.of(context).runtime;
  final gpu = await runtime.gpu;
  final need = ModelCatalog.needGb(s);
  final mem = gpu.memoryGb;
  if (mem == null || need == null || need <= mem) return true;
  if (!context.mounted) return false;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
      title: const Text('This model is too big for your graphics card'),
      content: SizedBox(
        width: 420,
        child: Text(
          'It needs about ${need.round()} GB of graphics memory and your '
          '${gpu.name ?? 'graphics card'} has ${mem.round()} GB. It will '
          'still work, but part of it runs on the main processor, so replies '
          'will be much slower.\n\n'
          'A smaller model or a shorter memory span would fit.',
          style: const TextStyle(height: 1.4),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Continue anyway'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Pick another'),
        ),
      ],
    ),
  );
  return go ?? false;
}

class _GpuBanner extends StatelessWidget {
  const _GpuBanner({required this.gpu, required this.recommended});

  final GpuInfo gpu;
  final CatalogModel? recommended;

  @override
  Widget build(BuildContext context) {
    final text = gpu.known
        ? 'Your graphics: ${gpu.label}. '
              '${recommended == null ? '' : 'Best fit: ${recommended!.name}.'}'
        : 'Could not detect your graphics card. 8 GB of graphics memory '
              'runs the 8B models well; pick Qwen3 4B if you are unsure.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.palette.tile,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            gpu.known ? Icons.developer_board_rounded : Icons.help_outline,
            size: 18,
            color: context.palette.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: context.palette.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The info icon used for setting hints: hover or tap for the text.
class InfoIcon extends StatelessWidget {
  const InfoIcon({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 12),
      waitDuration: const Duration(milliseconds: 200),
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.all(12),
      child: MouseRegion(
        cursor: SystemMouseCursors.help,
        child: Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: context.palette.textMuted,
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.title,
    required this.subtitle,
    this.warning,
    this.danger,
    this.uncensored = false,
    this.sees = false,
    this.recommended = false,
    required this.selected,
    required this.downloaded,
    required this.downloading,
    this.progress,
    this.onDownload,
    this.onCancel,
    required this.onUse,
  });

  final String title;
  final String subtitle;
  final String? warning;

  /// Shown in red, in place of [warning].
  final String? danger;
  final bool uncensored;

  /// Sees the pictures shared in the chat itself.
  final bool sees;
  final bool recommended;
  final bool selected;
  final bool downloaded;
  final bool downloading;
  final double? progress;
  final VoidCallback? onDownload;
  final VoidCallback? onCancel;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final noteColor = danger != null
        ? Theme.of(context).colorScheme.error
        : Colors.amberAccent;
    final Widget action;
    if (downloading) {
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              value: progress,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            progress == null ? '…' : '${(progress! * 100).round()}%',
            style: TextStyle(fontSize: 12, color: context.palette.textMuted),
          ),
          IconButton(
            tooltip: 'Pause download',
            onPressed: onCancel,
            icon: const Icon(Icons.pause_rounded),
          ),
        ],
      );
    } else if (selected) {
      action = Chip(
        avatar: Icon(Icons.check_rounded, color: accent, size: 18),
        label: const Text('In use'),
      );
    } else if (downloaded) {
      action = FilledButton.tonal(onPressed: onUse, child: const Text('Use'));
    } else {
      action = OutlinedButton.icon(
        onPressed: onDownload,
        icon: const Icon(Icons.download_rounded),
        label: const Text('Download'),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      decoration: BoxDecoration(
        color: context.palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? accent.withValues(alpha: 0.6) : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (recommended) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'Recommended for you',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                    if (sees) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message:
                            'Looks at the pictures you share itself, without '
                            'Eyes.',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.palette.tile,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'Sees pictures',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                    if (uncensored) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message:
                            'Safety tuning removed: it answers requests '
                            'other models refuse.',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.palette.tile,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'Uncensored',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: context.palette.textMuted,
                  ),
                ),
                if (danger ?? warning case final note?) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        danger != null
                            ? Icons.dangerous_rounded
                            : Icons.warning_amber_rounded,
                        size: 14,
                        color: noteColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          note,
                          style: TextStyle(
                            fontSize: 12,
                            color: noteColor,
                            fontWeight: danger != null
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 14),
          action,
        ],
      ),
    );
  }
}

/// Where downloads live, with buttons to open the folder or move it.
class _ModelsFolderRow extends StatelessWidget {
  const _ModelsFolderRow({
    required this.path,
    required this.onOpen,
    required this.onMove,
  });

  final String path;
  final VoidCallback onOpen;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: context.palette.tile,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_rounded,
            size: 20,
            color: context.palette.textMuted,
          ),
          const SizedBox(width: 10),
          Text(
            'Models folder',
            style: TextStyle(color: context.palette.textMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Tooltip(
              message: path,
              child: Text(displayPath(path), overflow: TextOverflow.ellipsis),
            ),
          ),
          TextButton(onPressed: onOpen, child: const Text('Open')),
          TextButton(onPressed: onMove, child: const Text('Move…')),
        ],
      ),
    );
  }
}

/// Settings → Brain → Advanced: the chat format for an attached model, and
/// the temperature. Both are left alone unless the user knows better.
class BrainAdvanced extends StatefulWidget {
  const BrainAdvanced({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<BrainAdvanced> createState() => _BrainAdvancedState();
}

class _BrainAdvancedState extends State<BrainAdvanced> {
  /// The temperature slider stays locked until the warning is accepted.
  bool _unlocked = false;

  AppSettings get _v => widget.value;

  Future<void> _unlock() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Change the temperature?'),
        content: const SizedBox(
          width: 400,
          child: Text(
            'Temperature sets how freely the model picks its words. Too low '
            'and replies get flat and repetitive; too high and they turn into '
            'nonsense, and memory and the other tools can stop working.\n\n'
            'This can definitely break your companion. If you don\'t know '
            'what it does, leave it on Recommended.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Leave it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    final builtIn = _v.llmMode == LlmMode.builtIn;
    final path = _v.modelPath;
    final catalog = path == null ? null : ModelCatalog.forPath(path);
    final recommended = builtIn ? catalog?.sampling['temperature'] : null;
    final recommendedText = recommended == null
        ? (builtIn ? "the model's default" : "the server's default")
        : recommended.toStringAsFixed(2);
    final custom = _v.temperature;
    final editing = custom != null || _unlocked;
    final muted = TextStyle(color: context.palette.textMuted, height: 1.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Advanced',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text('Leave these alone unless you know what they do.', style: muted),
        if (builtIn && path != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              if (catalog != null)
                Text(
                  'Chat format: '
                  '${ChatFormat.byTemplate(catalog.chatTemplate)?.label ?? 'from the model file'}'
                  ', set for ${catalog.name}',
                )
              else
                DropdownMenu<String>(
                  key: ValueKey(_v.chatFormat),
                  initialSelection: _v.chatFormat ?? '',
                  label: const Text('Chat format'),
                  width: 260,
                  onSelected: (f) => widget.onChanged(
                    f == null || f.isEmpty
                        ? _v.copyWith(clearChatFormat: true)
                        : _v.copyWith(chatFormat: f),
                  ),
                  dropdownMenuEntries: [
                    const DropdownMenuEntry(value: '', label: 'Automatic'),
                    for (final f in ChatFormat.values)
                      DropdownMenuEntry(value: f.name, label: f.label),
                  ],
                ),
              const SizedBox(width: 8),
              InfoIcon(
                message: catalog != null
                    ? 'How messages are laid out for the model. Models from '
                          'the list come with the format they were trained '
                          'on, picked for you.'
                    : 'How messages are laid out for the model. Each model '
                          'was trained on one; the wrong one makes it ignore '
                          'its character, write nonsense, or never use its '
                          'tools.\n\nAutomatic uses the format inside the '
                          'file. If replies go wrong, pick the format named '
                          "on the model's page (ChatML is the most common "
                          'for roleplay models).',
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('Temperature'),
            const SizedBox(width: 8),
            const InfoIcon(
              message:
                  'How freely the model picks its words: lower is steadier '
                  'and more predictable, higher is more surprising. '
                  'Recommended uses the value from the model\'s page.',
            ),
            const SizedBox(width: 12),
            if (!editing) ...[
              Text('Recommended ($recommendedText)', style: muted),
              const SizedBox(width: 12),
              TextButton(onPressed: _unlock, child: const Text('Change…')),
            ] else ...[
              Expanded(
                child: Slider(
                  value: (custom ?? recommended ?? 0.8).toDouble(),
                  min: 0,
                  max: 2,
                  divisions: 40,
                  label: (custom ?? recommended ?? 0.8).toStringAsFixed(2),
                  onChanged: (t) => widget.onChanged(
                    _v.copyWith(temperature: (t * 100).round() / 100),
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  (custom ?? recommended ?? 0.8).toStringAsFixed(2),
                  textAlign: TextAlign.end,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  setState(() => _unlocked = false);
                  widget.onChanged(_v.copyWith(clearTemperature: true));
                },
                child: const Text('Recommended'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
