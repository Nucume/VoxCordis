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
  llm('--llm'),

  /// The text encoder of Wan video models: `--t5xxl`.
  t5xxl('--t5xxl'),

  /// The second expert of Wan 2.2's 14B models: `--high-noise-diffusion-model`.
  highNoise('--high-noise-diffusion-model'),

  /// The sound decoder of LTX models: `--audio-vae`.
  audioVae('--audio-vae'),

  /// LTX's x2 latent upscaler. It isn't passed as a path: sd-cli finds it by
  /// name in the models folder, so the clip is made small and enlarged.
  upscaler('--hires-upscaler');

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
    this.convertTo,
    this.convertedName,
  });

  final ImageFileRole role;
  final String repo;
  final String revision;
  final String path;
  final String sha256;
  final double sizeGb;

  /// Squeezed once after the download with `sd-cli -M convert --type`, into
  /// a file called [convertedName]; the download is then deleted. LTX's text
  /// encoder only comes as a 26 GB bf16 file.
  final String? convertTo;
  final String? convertedName;

  /// The name the download is saved under.
  String get sourceName => p.posix.basename(path);

  /// Saved flat in the picture models folder under its own name, so two
  /// models that share a part (Anima's VAE) share the file.
  String get fileName => convertedName ?? sourceName;

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

/// A model that turns a picture into a short clip, run by sd-cli's video
/// mode. It lives in the `video/` folder of the models folder.
class VideoModel extends ImageModel {
  const VideoModel({
    required super.id,
    required super.name,
    required super.blurb,
    required super.files,
    required super.steps,
    required super.cfg,
    required super.sampler,
    required super.baseSize,
    super.negative,
    super.minMemoryGb,
    super.license,
    super.own,
    this.fps = 24,
    this.flowShift = 5.0,
    this.frameStep = 4,
    this.frameBase = 1,
    this.extraArgs = const [],
    this.sigmas,
    this.hiresSigmas,
    this.highNoiseSteps,
    this.baseGb = 9.2,
    this.gbPerSecond = 0.6,
    this.detailedPrompt = false,
    this.promptChars = 500,
    this.promptMax = 900,
  }) : super(style: 'moving pictures', prompting: Prompting.sentences);

  final int fps;

  /// Wan's flow shift; null for models that don't use one (LTX).
  final double? flowShift;

  /// Frames come in steps of this many plus one: Wan 4n + 1, LTX 8n + 1.
  final int frameStep;

  /// ... plus this many (Wan and LTX 1, MiniMax H3 5: 17k + 5).
  final int frameBase;

  /// Flags this model needs on top of the usual ones.
  final List<String> extraArgs;

  /// The exact noise schedule of a distilled model, and the one for its
  /// second pass when it enlarges the clip.
  final String? sigmas;
  final String? hiresSigmas;

  /// Makes the sound too (LTX).
  bool get hasSound => files.any((f) => f.role == ImageFileRole.audioVae);

  /// Likes a long, flowing prompt with sound described (LTX) rather than a
  /// short plain one (Wan).
  final bool detailedPrompt;

  /// About how long a prompt this model does best with, and the length past
  /// which it loses the thread (Wan likes short and direct, LTX a lot more).
  final int promptChars;
  final int promptMax;

  /// Steps of the second expert, for the 14B models that have one.
  final int? highNoiseSteps;

  /// Graphics memory in use at the start of a clip, and added per second.
  final double baseGb;
  final double gbPerSecond;

  static const shortest = 2;
  static const longest = 15;

  /// The frames for [seconds]; Wan needs 4n + 1, LTX 8n + 1, H3 17n + 5.
  int framesFor(int seconds) =>
      (seconds * fps / frameStep).round() * frameStep + frameBase;

  /// Graphics memory in use while making [seconds] of clip, from what
  /// was measured on a 3090: about 10 GB for 2 s and 15 GB for 10 s with
  /// Wan 2.2 5B (and peaks near 15.8 GB for 4 s with the 14B pair), so about
  /// [baseGb] plus [gbPerSecond] each second. A rough
  /// guess for other sizes and models, not a measurement.
  double usedGb(int seconds) => baseGb + gbPerSecond * seconds * _areaRatio;

  /// The pixels of a clip against the 384x512 the memory was measured at;
  /// the part that grows with the frames grows with them.
  double get _areaRatio {
    final size = sizeFor('portrait');
    return size.width * size.height / (384 * 512);
  }

  /// The longest clip, in seconds, that takes at most [fraction] of
  /// [cardGb]; 0 when not even [shortest] does.
  int _secondsWithin(double cardGb, double fraction) {
    var best = 0;
    for (var s = shortest; s <= longest; s++) {
      if (usedGb(s) <= cardGb * fraction) best = s;
    }
    return best;
  }

  /// How long a clip this card is likely to make without trouble.
  int safeSeconds(double cardGb) => _secondsWithin(cardGb, 0.9);

  /// The most it might manage, with the weights spilling into the
  /// computer's memory; beyond this it won't work.
  int mostSeconds(double cardGb) => _secondsWithin(cardGb, 1.35);
}

/// The picture models VoxCordis offers, and the human's own.
class ImageCatalog {
  static const _wan = 'QuantStack/Wan2.2-TI2V-5B-GGUF';
  static const _wanRev = '57437632ddd08bdcbd1508c866aa22e126ed51d2';
  static const _wanVae = ImageFile(
    role: ImageFileRole.vae,
    repo: _wan,
    revision: _wanRev,
    path: 'VAE/Wan2.2_VAE.safetensors',
    sha256: 'e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156',
    sizeGb: 1.41,
  );
  static const _umt5 = 'city96/umt5-xxl-encoder-gguf';
  static const _umt5Rev = 'b535255bee98c2b0a59ea7c0ae2dcd0c6657b3b7';

  static const _wanNegative =
      'blurry, static, still, low quality, worst quality, deformed, '
      'jpeg artifacts, subtitles, watermark, extra fingers';

  static const _umt5Q5 = ImageFile(
    role: ImageFileRole.t5xxl,
    repo: _umt5,
    revision: _umt5Rev,
    path: 'umt5-xxl-encoder-Q5_K_M.gguf',
    sha256: 'eaea358bb438c5d211721a4feecc162000e3636e9cb96f51e216f1f44ebd12ce',
    sizeGb: 4.15,
  );

  static const _wan14 = 'QuantStack/Wan2.2-I2V-A14B-GGUF';
  static const _wan14Rev = '6c6717459277b9cd1f72579d78a0fd62a79e57dc';

  static const _h3Gguf = 'leejet/MiniMax-H3-GGUF';
  static const _h3GgufRev = 'd9c4c6312b4728a68a15a35626d84775a6523783';
  static const _h3Comfy = 'Comfy-Org/MiniMax-H3';
  static const _h3ComfyRev = '912b6e38b2092ec4d2e86d24183e0d59ea059d48';

  static const _ltx = 'unsloth/LTX-2.5-GGUF';
  static const _ltxRev = 'ac3c540c6025903784336e99b2dc179385c4c3b7';

  /// LTX's parts, shared by both sizes. The text encoder is Gemma 4 12B
  /// tuned for LTX; it is downloaded as bf16 and squeezed to Q8 once.
  static const _ltxParts = <ImageFile>[
    ImageFile(
      role: ImageFileRole.llm,
      repo: _ltx,
      revision: _ltxRev,
      path: 'text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors',
      sha256:
          'ef7243612fdae7a75cb4d5cee9433e81380675fb6c213bd98ae74a9cd16561d1',
      sizeGb: 26.26,
      convertTo: 'q8_0',
      convertedName: 'gemma4-12b-with-proj-ltx-2.5-Q8_0.gguf',
    ),
    // The conv video decoder; sd.cpp doesn't implement the default one.
    ImageFile(
      role: ImageFileRole.vae,
      repo: _ltx,
      revision: _ltxRev,
      path: 'vae/ltx-2.5-video-vae-conv-bf16.safetensors',
      sha256:
          '685b06ee3d9b2039647698fc4ea33175112462fc374e2777312c907897dfce8d',
      sizeGb: 1.45,
    ),
    ImageFile(
      role: ImageFileRole.audioVae,
      repo: _ltx,
      revision: _ltxRev,
      path: 'vae/ltx-2.5-audio-vae-bf16.safetensors',
      sha256:
          'c52733d37f6a7fb7949c3dc0fb468c6cb2169e4d836983a73babb9f0d54837a5',
      sizeGb: 0.36,
    ),
    ImageFile(
      role: ImageFileRole.upscaler,
      repo: _ltx,
      revision: _ltxRev,
      path:
          'latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors',
      sha256:
          'eb5a71fe4068ee87ccdb1c3aa635e547ca76bd2d30ae20ae889f2c325c0677e8',
      sizeGb: 1.0,
    ),
  ];

  /// The distilled model's noise schedule (8 steps) and the one for the
  /// second pass after the x2 upscale (3 steps), as LTX publishes them.
  static const _ltxSigmas =
      '1.0,0.99375,0.9875,0.98125,0.975,0.909375,0.725,0.421875,0.0';
  static const _ltxHiresSigmas = '0.85,0.725,0.421875,0.0';

  /// Wan 2.2's 5B model first: the base of the clips, for cards with 12 GB
  /// or more. The 14B pair is the luxury for cards with 16 GB or more.
  static const videoModels = <VideoModel>[
    VideoModel(
      id: 'wan22-5b',
      name: 'Wan 2.2 5B',
      blurb:
          'Brings a picture to life as a short clip. Needs a card with 12 GB '
          'or more; a clip takes some minutes.',
      // The 5B packs 16 x 16 pixels into each latent step (the 14B 8 x 8),
      // so at 384x512 it saw a coarse 12 x 16 grid and drew distorted,
      // flashing bodies. 640x896 gives it a grid like the 14B's.
      baseSize: 768,
      steps: 30,
      cfg: 5,
      sampler: 'euler',
      minMemoryGb: 12,
      negative: _wanNegative,
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _wan,
          revision: _wanRev,
          path: 'Wan2.2-TI2V-5B-Q5_K_M.gguf',
          sha256:
              '4424633a876511b9be58a41119f7c9d762ea92b3cb74649cdb43cac850e42dba',
          sizeGb: 3.81,
        ),
        _wanVae,
        _umt5Q5,
      ],
    ),
    VideoModel(
      id: 'wan22-5b-q8',
      name: 'Wan 2.2 5B, finer',
      blurb:
          'The same model with less squeezed weights: smoother detail, a '
          'bit slower. For cards with 16 GB or more.',
      // The 5B packs 16 x 16 pixels into each latent step (the 14B 8 x 8),
      // so at 384x512 it saw a coarse 12 x 16 grid and drew distorted,
      // flashing bodies. 640x896 gives it a grid like the 14B's.
      baseSize: 768,
      steps: 30,
      cfg: 5,
      sampler: 'euler',
      minMemoryGb: 16,
      baseGb: 10,
      negative: _wanNegative,
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _wan,
          revision: _wanRev,
          path: 'Wan2.2-TI2V-5B-Q8_0.gguf',
          sha256:
              '57bece983817ab2f957546683bb670f13be7d99022d45674840cd999a050ea8f',
          sizeGb: 5.4,
        ),
        _wanVae,
        _umt5Q5,
      ],
    ),
    VideoModel(
      id: 'wan22-14b',
      name: 'Wan 2.2 14B',
      blurb:
          'The big one: clearly better motion and faces, with two expert '
          'models. For cards with 16 GB or more; a clip takes much longer.',
      baseSize: 448,
      steps: 10,
      highNoiseSteps: 8,
      flowShift: 3.0,
      cfg: 3.5,
      sampler: 'euler',
      minMemoryGb: 16,
      // Wan trains the 14B at 16 fps, but clips made at 16 looked jerky; 24
      // looks smooth (tested on a 3090). Memory measured at 97 frames (4 s).
      baseGb: 12.6,
      gbPerSecond: 0.8,
      negative: _wanNegative,
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _wan14,
          revision: _wan14Rev,
          path: 'LowNoise/Wan2.2-I2V-A14B-LowNoise-Q4_K_S.gguf',
          sha256:
              '54e2313ef7fbb169e72ab1d7cecdc90a04db01097c86f9f39097b8caacea50fb',
          sizeGb: 8.75,
        ),
        ImageFile(
          role: ImageFileRole.highNoise,
          repo: _wan14,
          revision: _wan14Rev,
          path: 'HighNoise/Wan2.2-I2V-A14B-HighNoise-Q4_K_S.gguf',
          sha256:
              '8fc5f726ccf1214e43c6a599bdef1e63daf7fab06e71fb74081416c4b9ce200b',
          sizeGb: 8.75,
        ),
        ImageFile(
          role: ImageFileRole.vae,
          repo: _wan14,
          revision: _wan14Rev,
          path: 'VAE/Wan2.1_VAE.safetensors',
          sha256:
              '2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b',
          sizeGb: 0.25,
        ),
        _umt5Q5,
      ],
    ),
    VideoModel(
      id: 'ltx25',
      name: 'LTX 2.5',
      blurb:
          'Clips with sound: it also makes voices, noises and music from '
          'your prompt. Big download (about 43 GB, 32 GB on disk after) and '
          'a card with 16 GB or more; a clip takes minutes.',
      // Made at half size and enlarged x2 by the upscaler: 768x1024 out.
      baseSize: 448,
      steps: 8,
      cfg: 1,
      sampler: 'euler',
      flowShift: null,
      frameStep: 8,
      sigmas: _ltxSigmas,
      hiresSigmas: _ltxHiresSigmas,
      minMemoryGb: 16,
      // Not measured yet; a guess from the file sizes.
      baseGb: 14,
      gbPerSecond: 0.5,
      detailedPrompt: true,
      promptChars: 2500,
      promptMax: 4000,
      license: 'LTX-2.x Community License',
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _ltx,
          revision: _ltxRev,
          path: 'distilled/ltx-2.5-22b-distilled-UD-Q4_K_XL.gguf',
          sha256:
              '55442750eb0013d94fffaa4dadb577c5f4dc07107ec04389d41444f6e517d980',
          sizeGb: 14.0,
        ),
        ..._ltxParts,
      ],
    ),
    VideoModel(
      id: 'ltx25-small',
      name: 'LTX 2.5, small',
      blurb:
          'The same, with the model squeezed harder so it fits a 12 GB '
          'card. Rougher detail. Same big shared download otherwise.',
      baseSize: 448,
      steps: 8,
      cfg: 1,
      sampler: 'euler',
      flowShift: null,
      frameStep: 8,
      sigmas: _ltxSigmas,
      hiresSigmas: _ltxHiresSigmas,
      minMemoryGb: 12,
      baseGb: 11,
      gbPerSecond: 0.5,
      detailedPrompt: true,
      promptChars: 2500,
      promptMax: 4000,
      license: 'LTX-2.x Community License',
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _ltx,
          revision: _ltxRev,
          path: 'distilled/ltx-2.5-22b-distilled-UD-Q2_K_XL.gguf',
          sha256:
              'd6fdc7e117f1a9780bdbe15c898d63c12a7d747847f54b276b69a6be5ce3c57d',
          sizeGb: 9.5,
        ),
        ..._ltxParts,
      ],
    ),
    VideoModel(
      id: 'minimax-h3',
      name: 'MiniMax H3',
      blurb:
          'Clips with sound from a 33 B model, in its pruned form: it also '
          'makes voices, noises and music. Very big download (about 35 GB) '
          'and a card with 16 GB or more, plus lots of computer memory; a '
          'clip takes a long time.',
      // Width and height must be multiples of 32; 512x768 is about the
      // 864x480 of its docs in pixels.
      baseSize: 640,
      steps: 20,
      cfg: 1,
      sampler: 'euler',
      // Its flow shift (12) is built in. It always runs at 24 fps and wants
      // 17k + 5 frames (56 for 2 s).
      flowShift: null,
      frameStep: 17,
      frameBase: 5,
      // mmap reads the weights from disk as needed instead of copying
      // them all into the computer's memory; the tiles keep the video
      // decoder small.
      extraArgs: ['--rng', 'cpu', '--mmap', '--vae-tiling'],
      minMemoryGb: 16,
      // Not measured yet; a guess.
      baseGb: 13,
      gbPerSecond: 0.4,
      detailedPrompt: true,
      promptChars: 2000,
      promptMax: 4000,
      license: 'MiniMax H3 Community License',
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _h3Gguf,
          revision: _h3GgufRev,
          path: 'minimax_h3_fl2va_pruned-Q4_K_M.gguf',
          sha256:
              'dd948e08ad0ba3c71bd42f368e283dd82e790f5122a63b276e22a3e0283d0c10',
          sizeGb: 11.42,
        ),
        ImageFile(
          role: ImageFileRole.llm,
          repo: _h3Gguf,
          revision: _h3GgufRev,
          path: 'qwen3vl_32b_minimax_h3-Q4_K_M.gguf',
          sha256:
              '11e6efe70a57ce7f4838c47bdbd1a1c4b8ce10e2b7747f1b065990b70f4b05fc',
          sizeGb: 18.22,
        ),
        ImageFile(
          role: ImageFileRole.vae,
          repo: _h3Comfy,
          revision: _h3ComfyRev,
          path: 'vae/minimax_h3_video_vae_fp16.safetensors',
          sha256:
              '7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522',
          sizeGb: 5.21,
        ),
        ImageFile(
          role: ImageFileRole.audioVae,
          repo: _h3Comfy,
          revision: _h3ComfyRev,
          path: 'vae/minimax_h3_audio_vae_fp32.safetensors',
          sha256:
              '8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48',
          sizeGb: 0.61,
        ),
      ],
    ),
    VideoModel(
      id: 'minimax-h3-lighter',
      name: 'MiniMax H3, lighter',
      blurb:
          'The same, with the text encoder squeezed harder (a bit rougher '
          'understanding of your prompt) so it needs about 5 GB less memory '
          'and download (about 30 GB). Try this one if the other runs out '
          'of memory.',
      // Width and height must be multiples of 32; 512x768 is about the
      // 864x480 of its docs in pixels.
      baseSize: 640,
      steps: 20,
      cfg: 1,
      sampler: 'euler',
      // Its flow shift (12) is built in. It always runs at 24 fps and wants
      // 17k + 5 frames (56 for 2 s).
      flowShift: null,
      frameStep: 17,
      frameBase: 5,
      // mmap reads the weights from disk as needed instead of copying
      // them all into the computer's memory; the tiles keep the video
      // decoder small.
      extraArgs: ['--rng', 'cpu', '--mmap', '--vae-tiling'],
      minMemoryGb: 16,
      // Not measured yet; a guess.
      baseGb: 13,
      gbPerSecond: 0.4,
      detailedPrompt: true,
      promptChars: 2000,
      promptMax: 4000,
      license: 'MiniMax H3 Community License',
      files: [
        ImageFile(
          role: ImageFileRole.diffusion,
          repo: _h3Gguf,
          revision: _h3GgufRev,
          path: 'minimax_h3_fl2va_pruned-Q4_K_M.gguf',
          sha256:
              'dd948e08ad0ba3c71bd42f368e283dd82e790f5122a63b276e22a3e0283d0c10',
          sizeGb: 11.42,
        ),
        ImageFile(
          role: ImageFileRole.llm,
          repo: _h3Gguf,
          revision: _h3GgufRev,
          path: 'qwen3vl_32b_minimax_h3-Q2_K_M.gguf',
          sha256:
              'a8ccadccd57ef34c838ffb8a7da8368bb554721b2760274a1d3b0df63960b997',
          sizeGb: 13.1,
        ),
        ImageFile(
          role: ImageFileRole.vae,
          repo: _h3Comfy,
          revision: _h3ComfyRev,
          path: 'vae/minimax_h3_video_vae_fp16.safetensors',
          sha256:
              '7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522',
          sizeGb: 5.21,
        ),
        ImageFile(
          role: ImageFileRole.audioVae,
          repo: _h3Comfy,
          revision: _h3ComfyRev,
          path: 'vae/minimax_h3_audio_vae_fp32.safetensors',
          sha256:
              '8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48',
          sizeGb: 0.61,
        ),
      ],
    ),
  ];

  /// Where video models live: `video/` in the models folder.
  static Directory videoFor(AppSettings s) =>
      Directory(p.join(ModelCatalog.dirFor(s).path, 'video'));

  /// Own files in [dir]: finetunes of Wan 2.2 5B, run with its VAE and
  /// text encoder (which must be downloaded with it).
  static List<VideoModel> ownVideo(Directory dir) {
    if (!dir.existsSync()) return const [];
    final ours = {
      for (final m in videoModels)
        for (final f in m.files) f.fileName.toLowerCase(),
    };
    final base = videoModels.first;
    final found = <VideoModel>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!modelExtensions.contains(p.extension(name).toLowerCase()) ||
          ours.contains(name.toLowerCase())) {
        continue;
      }
      found.add(
        VideoModel(
          id: name,
          name: p.basenameWithoutExtension(name),
          blurb:
              'Your own file, run as a Wan 2.2 5B finetune. It needs Wan 2.2 '
              '5B\'s VAE and text encoder, which come with that download.',
          baseSize: base.baseSize,
          steps: base.steps,
          cfg: base.cfg,
          sampler: base.sampler,
          negative: base.negative,
          own: true,
          files: [
            ImageFile(
              role: ImageFileRole.diffusion,
              repo: '',
              revision: '',
              path: name,
              sha256: '',
              sizeGb: e.lengthSync() / 1e9,
            ),
            ...base.files.skip(1),
          ],
        ),
      );
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return found;
  }

  /// The video models that are downloaded.
  static List<VideoModel> availableVideo(Directory dir) => [
    for (final m in [...videoModels, ...ownVideo(dir)])
      if (installed(dir, m)) m,
  ];

  /// Every catalog model, picture and video.
  static Iterable<ImageModel> get allModels => [...models, ...videoModels];

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
      for (final m in allModels)
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
