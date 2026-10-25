import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import '../folder_service.dart';
import 'gpu_info.dart';

/// A model the app offers to download. All are GGUF files on Hugging Face,
/// mostly quantised to Q4_K_M (good quality for the size).
class CatalogModel {
  const CatalogModel({
    required this.id,
    required this.name,
    required this.blurb,
    required this.sizeGb,
    required this.minMemoryGb,
    required this.repo,
    required this.revision,
    required this.sha256,
    required this.file,
    this.parts = const [],
    this.uncensored = false,
    this.huge = false,
    this.chatTemplate,
    this.sampling = const {},
  });

  final String id;
  final String name;
  final String blurb;
  final double sizeGb;

  /// Rough VRAM (or RAM, when running on the CPU) needed for 8k context:
  /// weights, about 1.2 GB of conversation cache and working buffers.
  final int minMemoryGb;
  final String repo;

  /// The Hugging Face commit the files come from. Pinned, with [sha256],
  /// so a changed upload (or a swapped one) is never what gets loaded:
  /// llama.cpp has had memory-safety bugs in its GGUF reader.
  final String revision;

  /// Every file's SHA-256, as Hugging Face lists it for [revision].
  final Map<String, String> sha256;

  /// Path inside the repo of the file llama-server loads.
  final String file;

  /// The other files of a split model. They are saved next to [file], where
  /// llama.cpp finds them by name.
  final List<String> parts;

  /// Safety tuning removed (abliterated or uncensored finetune). Shown with a
  /// badge and never recommended.
  final bool uncensored;

  /// Far beyond a normal PC: the app warns before downloading and never
  /// recommends it.
  final bool huge;

  /// Name of a template in `assets/chat_templates/` that replaces the one in
  /// the GGUF. Many finetunes ship a plain template without tool calling (or
  /// none at all), which leaves the memory tools unused.
  final String? chatTemplate;

  /// Sampler settings sent with every request (llama-server names), from
  /// the model's card. Empty means llama-server's defaults.
  final Map<String, num> sampling;

  /// Every file to fetch, the one llama-server loads last, so a finished
  /// [file] means the whole model is there.
  List<String> get allFiles => [...parts, file];

  Uri urlFor(String path) =>
      Uri.parse('https://huggingface.co/$repo/resolve/$revision/$path');
}

/// The common chat formats a user can pick for an attached .gguf whose own
/// template is missing or wrong. Each names a template in
/// `assets/chat_templates/` that supports tool calls.
enum ChatFormat {
  chatml('ChatML', 'chatml-tools'),
  mistral('Mistral', 'mistral-nemo-tools'),
  llama3('Llama 3', 'llama3-tools'),
  qwen3('Qwen3', 'qwen3');

  const ChatFormat(this.label, this.template);
  final String label;
  final String template;

  static ChatFormat? byName(String? name) =>
      ChatFormat.values.asNameMap()[name];

  static ChatFormat? byTemplate(String? template) =>
      ChatFormat.values.where((f) => f.template == template).firstOrNull;

  /// The template llama-server gets for [s]: a catalog model's own, else
  /// the user's pick, else none (the one inside the file).
  static String? templateFor(AppSettings s) {
    final path = s.modelPath;
    final model = path == null ? null : ModelCatalog.forPath(path);
    if (model != null) return model.chatTemplate;
    return byName(s.chatFormat)?.template;
  }
}

class ModelCatalog {
  static const models = <CatalogModel>[
    CatalogModel(
      id: 'qwen3-8b',
      name: 'Qwen3 8B',
      blurb: 'Balanced all-rounder. Reliable with memory tools.',
      sizeGb: 5.0,
      minMemoryGb: 7,
      repo: 'bartowski/Qwen_Qwen3-8B-GGUF',
      revision: '0b69f75b7472688e6808490aa2b85efdb81b5ce7',
      sha256: {
        'Qwen_Qwen3-8B-Q4_K_M.gguf':
            '54fffa050078e984116639c83dfb64b5aa6d4cd474e018b076777c632bbccccd',
      },
      file: 'Qwen_Qwen3-8B-Q4_K_M.gguf',
      // Qwen's card, thinking mode: Temperature=0.6, TopP=0.95, TopK=20,
      // MinP=0.
      sampling: {'temperature': 0.6, 'top_p': 0.95, 'top_k': 20, 'min_p': 0},
    ),
    CatalogModel(
      id: 'mistral-nemo-12b',
      name: 'Mistral Nemo 12B',
      blurb: 'Warmer, more creative voice. Popular for companions.',
      sizeGb: 7.5,
      minMemoryGb: 10,
      repo: 'bartowski/Mistral-Nemo-Instruct-2407-GGUF',
      revision: 'a2dd64a0a76ea1bdb2bb6ab6fa5496b003c7c908',
      sha256: {
        'Mistral-Nemo-Instruct-2407-Q4_K_M.gguf':
            '7c1a10d202d8788dbe5628dc962254d10654c853cae6aaeca0618f05490d4a46',
      },
      file: 'Mistral-Nemo-Instruct-2407-Q4_K_M.gguf',
      // The file's own template pastes the system prompt in front of the
      // latest message, where the companion prompt drowns out the history:
      // she greeted the human anew every turn. Ours puts it first.
      chatTemplate: 'mistral-nemo-tools',
      // Mistral: "Mistral Nemo requires smaller temperatures. We recommend
      // to use a temperature of 0.3."
      sampling: {'temperature': 0.3},
    ),
    CatalogModel(
      id: 'llama-3.1-8b',
      name: 'Llama 3.1 8B',
      blurb: 'Well-known and steady. Good tool calling.',
      sizeGb: 4.9,
      minMemoryGb: 7,
      repo: 'bartowski/Meta-Llama-3.1-8B-Instruct-GGUF',
      revision: 'bf5b95e96dac0462e2a09145ec66cae9a3f12067',
      sha256: {
        'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf':
            '7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c',
      },
      file: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
      // Meta's generation_config.json.
      sampling: {'temperature': 0.6, 'top_p': 0.9},
    ),
    CatalogModel(
      id: 'qwen3-4b',
      name: 'Qwen3 4B',
      blurb: 'Small and quick, for laptops without a big GPU.',
      sizeGb: 2.5,
      minMemoryGb: 5,
      repo: 'bartowski/Qwen_Qwen3-4B-GGUF',
      revision: 'cb76885dc66d50759b207c5a48c4e78dfa00c638',
      sha256: {
        'Qwen_Qwen3-4B-Q4_K_M.gguf':
            'fbe1d5edd4ce802ae3ae7c7e4ab7d09789d697fdac1fc7929f8df4ca3c41bae3',
      },
      file: 'Qwen_Qwen3-4B-Q4_K_M.gguf',
      // Qwen's card, thinking mode: Temperature=0.6, TopP=0.95, TopK=20,
      // MinP=0.
      sampling: {'temperature': 0.6, 'top_p': 0.95, 'top_k': 20, 'min_p': 0},
    ),
    // Uncensored picks, tested on llama.cpp b11400. Their GGUFs ship plain
    // templates without tool calling, so each brings its own.
    CatalogModel(
      id: 'rocinante-12b',
      name: 'Rocinante 12B',
      blurb:
          'Roleplay finetune with a lively, affectionate voice. Strong at '
          'romance and NSFW, and reliable with memory tools.',
      sizeGb: 7.5,
      minMemoryGb: 10,
      repo: 'bartowski/Rocinante-12B-v1.1-GGUF',
      revision: '9d15ca24c675a428fc5821cccc537f2a6f64987d',
      sha256: {
        'Rocinante-12B-v1.1-Q4_K_M.gguf':
            '5133341741709aafcbc162c8fe638143e466288b7942ba7a0e9d9ef4e08d056f',
      },
      file: 'Rocinante-12B-v1.1-Q4_K_M.gguf',
      uncensored: true,
      // Its GGUF has no template at all. The card names ChatML for
      // roleplay (Mistral's format makes it ignore the character), temp 0.7
      // and DRY against repetition.
      chatTemplate: 'chatml-tools',
      sampling: {'temperature': 0.7, 'dry_multiplier': 0.8},
    ),
    CatalogModel(
      id: 'mag-mell-12b',
      name: 'Mag-Mell 12B',
      blurb:
          'Roleplay finetune with the warmest, most playful voice. Strong at '
          'romance and NSFW, swears freely. Uses memory tools on its own.',
      sizeGb: 7.5,
      minMemoryGb: 10,
      repo: 'mradermacher/MN-12B-Mag-Mell-R1-GGUF',
      revision: '9622e5fc1fa07f3daeccbd4fc6a630548852f205',
      sha256: {
        'MN-12B-Mag-Mell-R1.Q4_K_M.gguf':
            'd7047a06e69ef62dfd9c1bdd46a7374adde7c1eb485529d3f545c2b6c6e81066',
      },
      file: 'MN-12B-Mag-Mell-R1.Q4_K_M.gguf',
      uncensored: true,
      // The card: ChatML (its base is Mistral-Nemo-Base-2407-chatml),
      // "tested with Temp 1.25 and MinP 0.2".
      chatTemplate: 'chatml-tools',
      sampling: {'temperature': 1.25, 'min_p': 0.2},
    ),
    CatalogModel(
      id: 'qwen3-8b-abliterated',
      name: 'Qwen3 8B Abliterated',
      blurb:
          'Qwen3 with refusals removed. Thinks before answering and is the '
          'most reliable with memory. Tame for roleplay, a bit assistant-like.',
      sizeGb: 5.0,
      minMemoryGb: 7,
      repo: 'mradermacher/Huihui-Qwen3-8B-abliterated-v2-GGUF',
      revision: '64c8e52a68276ef181b7695813c5883070b783a0',
      sha256: {
        'Huihui-Qwen3-8B-abliterated-v2.Q4_K_M.gguf':
            '0bdba3b32d450374b3c404d9ad531703db139b33798149efc84e2bce45eedbb5',
      },
      file: 'Huihui-Qwen3-8B-abliterated-v2.Q4_K_M.gguf',
      uncensored: true,
      chatTemplate: 'qwen3',
      // Qwen's card, thinking mode: Temperature=0.6, TopP=0.95, TopK=20,
      // MinP=0.
      sampling: {'temperature': 0.6, 'top_p': 0.95, 'top_k': 20, 'min_p': 0},
    ),
    CatalogModel(
      id: 'dolphin3-8b',
      name: 'Dolphin 3 8B',
      blurb:
          'General uncensored model. Goes along with anything, but the writing '
          'is plain. Saves memories when asked.',
      sizeGb: 4.9,
      minMemoryGb: 7,
      repo: 'bartowski/Dolphin3.0-Llama3.1-8B-GGUF',
      revision: 'a6274707ba8c5f12d4521eabbce1b318bb2f27f5',
      sha256: {
        'Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf':
            '268390e07edd407ad93ea21a868b7ae995b5950e01cad0db9e1802ae5049d405',
      },
      file: 'Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf',
      uncensored: true,
      // The card: "We use ChatML for the chat template." No sampler advice.
      chatTemplate: 'chatml-tools',
    ),
    // 321B mixture of experts at its smallest quant (UD-IQ1_S), in three
    // parts. Only for workstations with ~100 GB of graphics plus main memory.
    CatalogModel(
      id: 'glm-5.3-flash-abliterated',
      name: 'GLM-5.3 Flash Abliterated',
      blurb: 'Huge 321B model with its refusals removed. Workstations only.',
      sizeGb: 93.1,
      minMemoryGb: 100,
      repo: 'huihui-ai/Huihui-GLM-5.3-Flash-abliterated-GGUF',
      revision: 'c43a994637c10f5c376b7a471b3afc7663f80b9b',
      sha256: {
        'UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00001-of-00003.gguf':
            '909a8a2dedb493c5a694facfd1e0e9a3309ac66fbb9d270c024ff5d12e0d565f',
        'UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00002-of-00003.gguf':
            '43da40c25ea07e1e77df84dd631a3da7da1dd54bd44fa7fdfd72c14ebee03060',
        'UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00003-of-00003.gguf':
            '4dd80f68448de1a9e32a2c0393db6c5fd76e2b9ccfdf5f11a99cf2ec6b74576a',
      },
      file: 'UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00001-of-00003.gguf',
      parts: [
        'UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00002-of-00003.gguf',
        'UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00003-of-00003.gguf',
      ],
      uncensored: true,
      huge: true,
      // Z.ai's evaluation settings; its own template comes in the file.
      sampling: {'temperature': 1.0, 'top_p': 0.95},
    ),
  ];

  /// The best model that fits the card, or the smallest when none does.
  /// Null when the card is unknown.
  static CatalogModel? recommendFor(GpuInfo gpu) {
    final mem = gpu.memoryGb;
    if (mem == null) return null;
    CatalogModel? best;
    for (final m in models) {
      if (m.uncensored || m.huge) continue;
      // Keep a little headroom for the desktop and the 8k memory span.
      if (m.minMemoryGb > mem - 0.5) continue;
      if (best == null || m.minMemoryGb > best.minMemoryGb) best = m;
    }
    return best ??
        models
            .where((m) => !m.uncensored && !m.huge)
            .reduce((a, b) => a.minMemoryGb <= b.minMemoryGb ? a : b);
  }

  /// Graphics memory the chosen model needs at the chosen memory span.
  /// Attached files are judged by size. Null when there is no model.
  static double? needGb(AppSettings s) {
    final path = s.modelPath;
    if (path == null) return null;
    double? base = forPath(path)?.minMemoryGb.toDouble();
    if (base == null) {
      final f = File(path);
      if (!f.existsSync()) return null;
      base = f.lengthSync() / (1024 * 1024 * 1024) * 1.15 + 1;
    }
    return estimateNeedGb(baseGb: base, contextSize: s.contextSize);
  }

  /// The catalog entry a model file was downloaded for, if any. Matched by
  /// file name, so a moved or attached copy is still recognised.
  static CatalogModel? forPath(String path) {
    final name = p.basename(path).toLowerCase();
    for (final m in models) {
      if (p.posix.basename(m.file).toLowerCase() == name) return m;
    }
    return null;
  }

  /// Where downloads go unless the user picked another folder:
  /// `~/VoxCordis/models` (`%USERPROFILE%\VoxCordis\models` on Windows), in
  /// plain sight, because these files are gigabytes the user may want to
  /// find, back up or delete.
  static String get defaultDir =>
      VoxCordisFolder.models(VoxCordisFolder.defaultRoot);

  static Directory dirFor(AppSettings s) =>
      Directory(s.modelsFolder ?? defaultDir);

  static File fileFor(Directory modelsDir, CatalogModel m) =>
      partFor(modelsDir, m.file);

  /// Where one file of a catalog model is saved: flat in the models folder.
  static File partFor(Directory modelsDir, String path) =>
      File(p.join(modelsDir.path, p.posix.basename(path)));

  /// Every finished .gguf in the models folder.
  static Future<List<File>> downloaded(Directory modelsDir) async {
    if (!await modelsDir.exists()) return const [];
    return modelsDir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.gguf'))
        .cast<File>()
        .toList();
  }

  /// Moves every file in [from] into [to]: a rename where possible, a copy
  /// and delete onto another drive. A file already in [to] is left where it
  /// is. [onFile] is told each file's name before it moves.
  static Future<void> moveFolder(
    Directory from,
    Directory to, {
    void Function(String name, int index, int count)? onFile,
  }) async {
    if (!await from.exists()) return;
    await to.create(recursive: true);
    final files = await from.list().where((e) => e is File).toList();
    for (final (i, f) in files.indexed) {
      final name = p.basename(f.path);
      final target = File(p.join(to.path, name));
      if (await target.exists()) continue;
      onFile?.call(name, i, files.length);
      try {
        await f.rename(target.path);
      } on FileSystemException {
        // Another drive: copy beside the target first, so a cut-off copy
        // never looks like a finished model.
        final tmp = await (f as File).copy('${target.path}.moving');
        await tmp.rename(target.path);
        await f.delete();
      }
    }
    try {
      await from.delete(); // only if it is empty now
    } on FileSystemException {
      // Something stayed behind; leave the folder.
    }
  }

  /// [path] as it is after [from] moved to [to]; unchanged if it was
  /// elsewhere.
  static String? movedPath(String? path, Directory from, Directory to) {
    if (path == null || !p.isWithin(from.path, path)) return path;
    return p.join(to.path, p.relative(path, from: from.path));
  }
}
