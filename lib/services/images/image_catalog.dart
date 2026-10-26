import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/settings.dart';
import '../runtime/model_catalog.dart';

/// What a file is to stable-diffusion.cpp.
enum ImageFileRole {
  /// A whole checkpoint (SD 1.x, SDXL and their finetunes): `-m`.
  checkpoint('-m'),

  /// The diffusion part of a model that comes in pieces: `--diffusion-model`.
  diffusion('--diffusion-model'),
  vae('--vae'),

  /// The language model some newer models read the prompt with: `--llm`.
  llm('--llm');

  const ImageFileRole(this.flag);
  final String flag;
}

/// One file of a picture model on Hugging Face, pinned like the chat
/// models: a fixed commit and its SHA-256.
class ImageFile {
  const ImageFile({
    required this.role,
    required this.repo,
    required this.revision,
    required this.path,
    required this.sha256,
    required this.sizeGb,
  });

  final ImageFileRole role;
  final String repo;
  final String revision;
  final String path;
  final String sha256;
  final double sizeGb;

  /// Saved flat in the picture models folder under its own name, so two
  /// models that share a part (Anima's VAE) share the file.
  String get fileName => p.posix.basename(path);

  Uri get url =>
      Uri.parse('https://huggingface.co/$repo/resolve/$revision/$path');
}

/// How a model likes to be asked.
enum Prompting {
  /// Danbooru-style tags: lowercase, comma-separated, quality tags first.
  tags,

  /// Plain descriptive sentences.
  sentences,

  /// Either, or both mixed.
  both,
}

/// A picture model: its files and the settings its makers recommend.
class ImageModel {
  const ImageModel({
    required this.id,
    required this.name,
    required this.blurb,
    required this.style,
    required this.files,
    required this.prompting,
    required this.steps,
    required this.cfg,
    required this.sampler,
    this.scheduler,
    this.baseSize = 1024,
    this.prefix = '',
    this.suffix = '',
    this.negative = '',
    this.minMemoryGb = 8,
    this.license,
    this.own = false,
  });

  /// A catalog id, or for the human's own file its file name.
  final String id;
  final String name;
  final String blurb;

  /// A word or two for the companion: "anime", "photos", "anything".
  final String style;
  final List<ImageFile> files;
  final Prompting prompting;
  final int steps;
  final double cfg;
  final String sampler;
  final String? scheduler;

  /// The side of a square picture; portraits and landscapes keep about
  /// the same number of pixels.
  final int baseSize;

  /// Put before every prompt (quality tags the model was trained on).
  final String prefix;

  /// Put after every prompt, for models whose cards want the quality tags
  /// last.
  final String suffix;
  final String negative;

  /// Rough graphics memory for drawing at [baseSize] without spilling into
  /// the computer's memory.
  final int minMemoryGb;

  /// Shown under the name when the model's own license limits its use.
  final String? license;

  /// A file the human added themselves rather than one from the catalog.
  final bool own;

  /// The whole download, shared parts included.
  double get sizeGb => files.fold(0.0, (sum, f) => sum + f.sizeGb);

  /// Width and height for [shape] ("square", "portrait", "landscape").
  ({int width, int height}) sizeFor(String? shape) {
    final long = (baseSize * 1.1875 / 64).round() * 64;
    final short = (baseSize * 0.8125 / 64).round() * 64;
    return switch (shape) {
      'portrait' => (width: short, height: long),
      'landscape' => (width: long, height: short),
      _ => (width: baseSize, height: baseSize),
    };
  }

  String get promptingHint => switch (prompting) {
    Prompting.tags =>
      'Danbooru-style tags: lowercase, comma-separated, like "1girl, '
          'long hair, smile, cherry blossoms"',
    Prompting.sentences => 'a description in plain sentences',
    Prompting.both => 'Danbooru-style tags, plain sentences, or both mixed',
  };
}

/// The picture models VoxCordis offers, and the human's own.
class ImageCatalog {
  static const _anima = 'circlestone-labs/Anima';
  static const _animaRev = 'f973fc41ec7545364ac9776c2440285f43ff2a30';

  static const _animaVae = ImageFile(
    role: ImageFileRole.vae,
    repo: _anima,
    revision: _animaRev,
    path: 'split_files/vae/qwen_image_vae.safetensors',
    sha256: 'a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f',
    sizeGb: 0.25,
  );
  static const _animaLlm = ImageFile(
    role: ImageFileRole.llm,
    repo: _anima,
    revision: _animaRev,
    path: 'split_files/text_encoders/qwen_3_06b_base.safetensors',
    sha256: 'cd2a512003e2f9f3cd3c32a9c3573f820bb28c940f73c57b1ddaa983d9223eba',
    sizeGb: 1.19,
  );

  /// Anima's card: "Recommended negative" for the non-turbo versions.
  static const _animaNegative =
      'worst quality, low quality, score_1, score_2, score_3, artist name, '
      'blurry, jpeg artifacts, chromatic aberration';

  static const _animaLicense =
      'Non-commercial model license; the pictures you make are yours to use.';

  /// SDXL's own VAE gives black pictures in half precision; this one
  /// doesn't.
  static const _sdxlVae = ImageFile(
    role: ImageFileRole.vae,
    repo: 'madebyollin/sdxl-vae-fp16-fix',
    revision: '207b116dae70ace3637169f1ddd2434b91b3a8cd',
    path: 'sdxl_vae.safetensors',
    sha256: '235745af8d86bf4a4c1b5b4f529868b37019a10f7c0b2e79ad0abca3a22bc6e1',
    sizeGb: 0.33,
  );

  static const models = <ImageModel>[
    ImageModel(
      id: 'sdxl',
      name: 'Stable Diffusion XL',
      blurb: 'The classic all-rounder: any subject, any style.',
      style: 'anything',
      prompting: Prompting.sentences,
      steps: 30,
      cfg: 7,
      sampler: 'euler_a',
      negative: 'blurry, low quality, deformed, watermark, text',
      files: [
        ImageFile(
          role: ImageFileRole.checkpoint,
          repo: 'stabilityai/stable-diffusion-xl-base-1.0',
          revision: '462165984030d82259a11f4367a4eed129e94a7b',
          path: 'sd_xl_base_1.0.safetensors',
          sha256:
              '31e35c80fc4829d14f90153f4c74cd59c90b779f6afe05a74cd6120b893f7e5b',
          sizeGb: 6.94,
        ),
        _sdxlVae,
      ],
    ),
    ImageModel(
      id: 'anima-turbo',
      name: 'Anima Turbo',
      blurb:
          'Anime and illustration, fast: about ten steps a picture. Its '
          'makers\' pick to start with.',
      style: 'anime',
      prompting: Prompting.both,
      // The card: "Use at CFG 1 and 8-12 steps."
      steps: 10,
      cfg: 1,
      sampler: 'euler',
      prefix: 'masterpiece, best quality, ',
      minMemoryGb: 6,
      license: _animaLicense,
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _anima,
          revision: _animaRev,
          path: 'split_files/diffusion_models/anima-turbo-v1.1.safetensors',
          sha256:
              'fba11953276b57edf59d1dc4f1857ac05aa079c56f982b4d7c20298d57d3f7eb',
          sizeGb: 4.18,
        ),
        _animaVae,
        _animaLlm,
      ],
    ),
    ImageModel(
      id: 'anima',
      name: 'Anima Aesthetic',
      blurb:
          'Anime and illustration at their best, slower than Turbo. Knows '
          'characters, series and artists (@name).',
      style: 'anime',
      prompting: Prompting.both,
      // The card: 30-50 steps, CFG 4-5, er_sde as a neutral default.
      steps: 30,
      cfg: 4.5,
      sampler: 'er_sde',
      prefix: 'masterpiece, best quality, ',
      negative: _animaNegative,
      minMemoryGb: 6,
      license: _animaLicense,
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _anima,
          revision: _animaRev,
          path: 'split_files/diffusion_models/anima-aesthetic-v1.1.safetensors',
          sha256:
              '3c1868387a3a1ff504bbb87c33678321965ead381fcf87afbd0264daa600c082',
          sizeGb: 4.18,
        ),
        _animaVae,
        _animaLlm,
      ],
    ),
    ImageModel(
      id: 'animagine-xl-4',
      name: 'Animagine XL 4.0',
      blurb: 'Anime on SDXL, very good with Danbooru tags and characters.',
      style: 'anime',
      prompting: Prompting.tags,
      // The card: 28 steps, CFG 5, Euler Ancestral, quality tags at the
      // end.
      steps: 28,
      cfg: 5,
      sampler: 'euler_a',
      suffix: ', masterpiece, high score, great score, absurdres',
      negative:
          'lowres, bad anatomy, bad hands, text, error, missing finger, '
          'extra digits, fewer digits, cropped, worst quality, low quality, '
          'low score, bad score, average score, signature, watermark, '
          'username, blurry',
      files: [
        ImageFile(
          role: ImageFileRole.checkpoint,
          repo: 'cagliostrolab/animagine-xl-4.0',
          revision: '2b7c1b397761bf5bd3cc42e5b39ec99314a75a96',
          path: 'animagine-xl-4.0-opt.safetensors',
          sha256:
              '6327eca98bfb6538dd7a4edce22484a1bbc57a8cff6b11d075d40da1afb847ac',
          sizeGb: 6.94,
        ),
      ],
    ),
    ImageModel(
      id: 'realvisxl-5',
      name: 'RealVisXL 5.0',
      blurb: 'Photorealistic people, places and things.',
      style: 'photos',
      prompting: Prompting.sentences,
      // The card: DPM++ 2M Karras with 50+ steps (or DPM++ SDE Karras
      // with 30+), and its negative prompt.
      steps: 50,
      cfg: 5,
      sampler: 'dpm++2m',
      scheduler: 'karras',
      negative:
          'bad hands, bad anatomy, ugly, deformed, (face asymmetry, eyes '
          'asymmetry, deformed eyes, deformed mouth, open mouth)',
      files: [
        ImageFile(
          role: ImageFileRole.checkpoint,
          repo: 'SG161222/RealVisXL_V5.0',
          revision: 'ac93e0dda1f6d448cae19bbfab8c5e720a5e48bc',
          path: 'RealVisXL_V5.0_fp16.safetensors',
          sha256:
              '6a35a7855770ae9820a3c931d4964c3817b6d9e3c6f9c4dabb5b3a94e5643b80',
          sizeGb: 6.94,
        ),
      ],
    ),
  ];

  static ImageModel? byId(String id) =>
      models.where((m) => m.id == id).firstOrNull;

  static const modelExtensions = {'.safetensors', '.gguf', '.ckpt'};

  /// Where picture models live: `images/` in the models folder.
  static Directory dirFor(AppSettings s) =>
      Directory(p.join(ModelCatalog.dirFor(s).path, 'images'));

  /// Where LoRAs live: `loras/` in the models folder.
  static Directory lorasFor(AppSettings s) =>
      Directory(p.join(ModelCatalog.dirFor(s).path, 'loras'));

  static File fileIn(Directory dir, ImageFile f) =>
      File(p.join(dir.path, f.fileName));

  static bool installed(Directory dir, ImageModel m) =>
      m.files.every((f) => fileIn(dir, f).existsSync());

  /// Every model ready to draw with: the catalog's that are downloaded,
  /// then the human's own files.
  static List<ImageModel> available(Directory dir) => [
    for (final m in models)
      if (installed(dir, m)) m,
    ...own(dir),
  ];

  /// Files in [dir] that aren't part of a catalog model: whole checkpoints
  /// the human added (SD 1.5, SDXL, Pony, Illustrious and their finetunes).
  static List<ImageModel> own(Directory dir) {
    if (!dir.existsSync()) return const [];
    final ours = {
      for (final m in models)
        for (final f in m.files) f.fileName.toLowerCase(),
    };
    final found = <ImageModel>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!modelExtensions.contains(p.extension(name).toLowerCase()) ||
          ours.contains(name.toLowerCase())) {
        continue;
      }
      found.add(ownModel(e));
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return found;
  }

  /// One of the human's own checkpoints. Its kind isn't written anywhere
  /// stable-diffusion.cpp needs, but its settings are guessed from its
  /// size: under 3 GB is an SD 1.5 model, drawn at 512 pixels.
  static ImageModel ownModel(File file) {
    final name = p.basename(file.path);
    final small = file.lengthSync() < 3e9;
    return ImageModel(
      id: name,
      name: p.basenameWithoutExtension(name),
      blurb: 'Your own model file.',
      style: 'your own model',
      prompting: Prompting.both,
      steps: small ? 25 : 28,
      cfg: small ? 7 : 6,
      sampler: 'euler_a',
      baseSize: small ? 512 : 1024,
      negative: 'worst quality, low quality, blurry, watermark',
      own: true,
      files: [
        ImageFile(
          role: ImageFileRole.checkpoint,
          repo: '',
          revision: '',
          path: name,
          sha256: '',
          sizeGb: file.lengthSync() / 1e9,
        ),
      ],
    );
  }

  /// The LoRAs in [dir], by name (the file name without its extension),
  /// each with the note from a `.txt` file beside it, if there is one:
  /// trigger words and what it is for.
  static List<({String name, String note})> loras(Directory dir) {
    if (!dir.existsSync()) return const [];
    final out = <({String name, String note})>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final ext = p.extension(e.path).toLowerCase();
      if (ext != '.safetensors' && ext != '.gguf') continue;
      final name = p.basenameWithoutExtension(e.path);
      // sd-cli reads <lora:name:weight>; these would break the tag.
      if (name.contains(RegExp('[:<>]'))) continue;
      final txt = File(p.join(dir.path, '$name.txt'));
      var note = '';
      try {
        if (txt.existsSync() && txt.lengthSync() < 4000) {
          note = txt.readAsStringSync().trim().replaceAll(RegExp(r'\s+'), ' ');
        }
      } on FileSystemException {
        // No note.
      }
      out.add((name: name, note: note));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// The model [s] draws with when none is named: the chosen one if it is
  /// there, else the first one ready.
  static ImageModel? defaultFor(AppSettings s, List<ImageModel> ready) {
    for (final m in ready) {
      if (m.id == s.imageModel) return m;
    }
    return ready.firstOrNull;
  }
}
