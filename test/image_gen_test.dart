import 'dart:convert';
import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/services/images/clip_prompt.dart';
import 'package:companion/services/images/draw_tools.dart';
import 'package:companion/services/images/image_catalog.dart';
import 'package:companion/services/images/image_engine.dart';
import 'package:companion/services/images/sd_runtime.dart';
import 'package:companion/services/invoke_client.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A stand-in for sd-cli: prints progress like it, saves a small PNG where
/// -o says, and writes its arguments down for the test to read.
Future<String> _fakeSdCli(Directory dir) async {
  final png = File(p.join(dir.path, 'fixture.png'))
    ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
  final script = File(p.join(dir.path, 'sd-cli'))
    ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" > "${dir.path}/args.txt"
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then out="\$2"; fi
  shift
done
printf '\\r|==>   | 1/2 - 1.00s/it\\r|=====| 2/2 - 1.00s/it\\n'
cp "${png.path}" "\$out"
''');
  await Process.run('chmod', ['+x', script.path]);
  return script.path;
}

void main() {
  clipPromptTests();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('draw'));
  tearDown(() => tmp.delete(recursive: true));

  test('picks the sd-cli build for each computer', () {
    expect(
      SdInstaller.buildFor(os: 'linux', arm: false, gpu: true),
      'linux-vulkan',
    );
    expect(
      SdInstaller.buildFor(os: 'linux', arm: false, gpu: false),
      'linux-cpu',
    );
    expect(
      SdInstaller.buildFor(os: 'windows', arm: false, gpu: true),
      'windows-vulkan',
    );
    expect(
      SdInstaller.buildFor(os: 'macos', arm: true, gpu: false),
      'macos-arm64',
    );
    expect(SdInstaller.buildFor(os: 'macos', arm: false, gpu: true), isNull);
    for (final b in SdInstaller.builds.values.expand((files) => files)) {
      expect(b.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    expect(SdInstaller.cudaBuildFor(os: 'linux', arm: false), 'linux-cuda');
    expect(SdInstaller.cudaBuildFor(os: 'windows', arm: false), 'windows-cuda');
    expect(SdInstaller.builds['windows-cuda'], hasLength(2));
    expect(SdInstaller.cudaBuildFor(os: 'macos', arm: true), isNull);
  });

  group('CUDA drawing', () {
    File marker() =>
        File(p.join(tmp.path, 'draw', '${SdInstaller.pinnedTag}.no-cuda'));

    test('an NVIDIA card gets the CUDA sd-cli, else Vulkan', () async {
      final cuda = SdInstaller(tmp, nvidiaDriver: () async => 550);
      final plain = SdInstaller(tmp, nvidiaDriver: () async => null);
      final vulkan = await _fakeSdCli(
        cuda.installDir('linux-vulkan')..createSync(recursive: true),
      );
      // Nothing CUDA yet: it counts as missing, so it gets installed.
      expect(await cuda.find(gpu: true), isNull);
      expect(await plain.find(gpu: true), vulkan);
      final cudaExe = await _fakeSdCli(
        cuda.installDir('linux-cuda')..createSync(recursive: true),
      );
      expect(await cuda.find(gpu: true), cudaExe);
      expect(cuda.isCuda(cudaExe), isTrue);
      expect(cuda.isCuda(vulkan), isFalse);
      // The graphics card off: never CUDA.
      expect(await cuda.find(gpu: false), isNull);
      // Too old a driver for CUDA 12.
      expect(
        await SdInstaller(tmp, nvidiaDriver: () async => 470).find(gpu: true),
        vulkan,
      );
    }, skip: !Platform.isLinux);

    test(
      'no signed CUDA build: Vulkan, and not asked again for a day',
      () async {
        final logs = <String>[];
        final installer = SdInstaller(
          tmp,
          client: MockClient((_) async => http.Response('', 503)),
          nvidiaDriver: () async => 550,
        )..note = logs.add;
        final vulkan = await _fakeSdCli(
          installer.installDir('linux-vulkan')..createSync(recursive: true),
        );
        expect(await installer.ensureInstalled(gpu: true), vulkan);
        expect(marker().existsSync(), isTrue);
        expect(logs, contains(contains('HTTP 503')));
        expect(logs, contains(contains('Vulkan build of sd-cli')));
        expect(await installer.find(gpu: true), vulkan);
      },
      skip: !Platform.isLinux,
    );

    test('a CUDA sd-cli that will not start draws with Vulkan', () async {
      final installer = SdInstaller(tmp, nvidiaDriver: () async => 550);
      final cudaDir = installer.installDir('linux-cuda')
        ..createSync(recursive: true);
      File(p.join(cudaDir.path, 'sd-cli')).writeAsStringSync(
        '#!/bin/sh\n'
        'echo "ggml_cuda_init: failed to initialize CUDA: no CUDA-capable '
        'device is detected" >&2\n'
        'echo "[INFO ] main.cpp:885  - new_sd_ctx_t failed"\n'
        'exit 1\n',
      );
      await Process.run('chmod', ['+x', p.join(cudaDir.path, 'sd-cli')]);
      final vulkanDir = installer.installDir('linux-vulkan')
        ..createSync(recursive: true);
      await _fakeSdCli(vulkanDir);

      final settings = AppSettings(
        companionName: 'Mira',
        companionFolder: p.join(tmp.path, 'Mira'),
        modelsFolder: tmp.path,
        llmMode: LlmMode.external,
        imageEngine: ImageEngineChoice.builtIn,
      );
      final dir = ImageCatalog.dirFor(settings)..createSync(recursive: true);
      File(p.join(dir.path, 'mine.safetensors')).writeAsStringSync('x');
      final engine = ImageEngine(
        supportDir: tmp,
        runtime: RuntimeController(tmp),
        settings: () => settings,
        installer: installer,
      );
      final job = engine.draw(
        DrawJob(
          DrawRequest(
            model: ImageCatalog.available(dir).single,
            prompt: 'a cat',
          ),
          folder: settings.companionFolder!,
          forChat: false,
        ),
      );
      final picture = await job.done;
      expect(picture.existsSync(), isTrue);
      expect(marker().existsSync(), isTrue);
      expect(await installer.find(gpu: true), p.join(vulkanDir.path, 'sd-cli'));
    }, skip: !Platform.isLinux);

    test('only a CUDA that cannot run at all counts, not a full card', () {
      expect(
        SdRun.cudaWontStart(
          'ggml_cuda_init: failed to initialize CUDA: no CUDA-capable device',
        ),
        isTrue,
      );
      expect(
        SdRun.cudaWontStart(
          './sd-cli: error while loading shared libraries: libcudart.so.12: '
          'cannot open shared object file',
        ),
        isTrue,
      );
      expect(
        SdRun.cudaWontStart(
          'ggml_cuda_init: found 1 CUDA devices\n'
          '[ERROR] lora.cpp:12 - required lora not found',
        ),
        isFalse,
      );
      expect(SdRun.cudaWontStart('CUDA error: out of memory'), isFalse);
    });
  });

  test('every catalog file is pinned', () {
    for (final m in ImageCatalog.allModels) {
      for (final f in m.files) {
        expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.path);
        expect(f.revision, matches(RegExp(r'^[0-9a-f]{40}$')), reason: f.path);
      }
      expect(
        m.files.where((f) => f.role.name == 'checkpoint').length +
            m.files.where((f) => f.role.name == 'diffusion').length,
        1,
      );
    }
  });

  test('builds sd-cli arguments from the model card', () {
    final anima = ImageCatalog.byId('anima-turbo')!;
    final args = SdRun.args(
      DrawRequest(
        model: anima,
        prompt: '1girl, <lora:/etc/passwd:1> smile\nnight',
        shape: 'portrait',
        loras: const [(name: 'watercolor', weight: 0.7)],
      ),
      modelsDir: Directory('/m'),
      lorasDir: Directory('/l'),
      out: File('/o/x.png'),
      seed: 42,
    );
    String after(String flag) => args[args.indexOf(flag) + 1];
    expect(after('--diffusion-model'), '/m/anima-turbo-v1.1.safetensors');
    expect(after('--vae'), '/m/qwen_image_vae.safetensors');
    expect(after('--llm'), '/m/qwen_3_06b_base.safetensors');
    expect(
      after('-p'),
      'masterpiece, best quality, 1girl, smile night <lora:watercolor:0.7>',
    );
    expect(after('--cfg-scale'), '1.0');
    expect(after('--steps'), '10');
    expect(after('-W'), '832');
    expect(after('-H'), '1216');
    expect(after('-s'), '42');
    expect(after('--lora-model-dir'), '/l');
    expect(args, isNot(contains('-n')));

    final realvis = SdRun.args(
      DrawRequest(
        model: ImageCatalog.byId('realvisxl-5')!,
        prompt: 'a lighthouse',
        negative: 'fog',
        shape: 'landscape',
      ),
      modelsDir: Directory('/m'),
      lorasDir: Directory('/l'),
      out: File('/o/x.png'),
      seed: 1,
    );
    expect(
      realvis[realvis.indexOf('-m') + 1],
      '/m/RealVisXL_V5.0_fp16.safetensors',
    );
    expect(realvis[realvis.indexOf('-n') + 1], startsWith('fog, bad hands'));
    expect(realvis[realvis.indexOf('--scheduler') + 1], 'karras');
    expect(realvis[realvis.indexOf('-W') + 1], '1216');
    expect(realvis, isNot(contains('--lora-model-dir')));

    // The advanced sampler and scheduler win over the card; unknown names
    // (from another version's settings) are left to the card.
    List<String> withPicks(String? sampler, String? scheduler) => SdRun.args(
      DrawRequest(
        model: ImageCatalog.byId('sdxl')!,
        prompt: 'a lighthouse',
        sampler: sampler,
        scheduler: scheduler,
      ),
      modelsDir: Directory('/m'),
      lorasDir: Directory('/l'),
      out: File('/o/x.png'),
      seed: 1,
    );
    final picked = withPicks('dpm++2m', 'karras');
    expect(picked[picked.indexOf('--sampling-method') + 1], 'dpm++2m');
    expect(picked[picked.indexOf('--scheduler') + 1], 'karras');
    final odd = withPicks('warp_drive', 'nope');
    expect(odd[odd.indexOf('--sampling-method') + 1], 'euler_a');
    expect(odd, isNot(contains('--scheduler')));

    expect(SdRun.progressIn('\r|==>  | 5/20 - 1.23s/it'), (step: 5, steps: 20));
    expect(SdRun.progressIn('loading model'), isNull);
  });

  test('says why sd-cli couldn\'t load the model', () {
    final sdxl = ImageCatalog.byId('sdxl')!;
    final own = ImageCatalog.ownModel(
      File(p.join(tmp.path, 'flux.safetensors'))..writeAsStringSync('x'),
    );
    const failed = '[INFO ] main.cpp:885  - new_sd_ctx_t failed';
    String why(List<String> lines, [ImageModel? m]) =>
        SdRun.failureMessage(lines, m ?? sdxl);

    expect(
      why([
        'ggml_vulkan: Device memory allocation of size 2147483648 failed.',
        '[ERROR] stable-diffusion.cpp:600 - unet alloc params backend buffer failed',
        failed,
      ]),
      contains('ran out of memory'),
    );
    final unknown = why([
      "[ERROR] stable-diffusion.cpp:300 - get sd version from file failed: '/m/flux.safetensors'",
      failed,
    ], own);
    expect(unknown, contains('doesn\'t recognise flux'));
    expect(unknown, contains('whole checkpoint'));
    expect(
      why([
        "[ERROR] model.cpp:1000 - init model loader from file failed: '/m/sdxl_vae.safetensors'",
        failed,
      ]),
      contains('couldn\'t open sdxl_vae.safetensors'),
    );
    expect(
      why([
        "[ERROR] model.cpp:1700 - tensor 'x' has wrong shape in model file",
        failed,
      ]),
      contains('doesn\'t look like'),
    );
    expect(
      why(['[ERROR] lora.cpp:12 - something new broke', failed]),
      'The picture couldn\'t be drawn (something new broke).',
    );
    expect(why([failed]), contains('didn\'t say why'));
    expect(why([failed]), isNot(contains('new_sd_ctx_t')));
    expect(
      SdRun.failureMessage([failed], sdxl, clip: true),
      startsWith('The clip couldn\'t be made'),
    );
  });

  test('a missing model part is named before sd-cli runs', () async {
    final exe = await _fakeSdCli(tmp);
    final dir = Directory(p.join(tmp.path, 'models'))..createSync();
    final sdxl = ImageCatalog.byId('sdxl')!;
    File(p.join(dir.path, sdxl.files.first.fileName)).writeAsStringSync('x');
    await expectLater(
      SdRun.run(
        exe,
        DrawRequest(model: sdxl, prompt: 'a cat'),
        modelsDir: dir,
        lorasDir: dir,
        out: File(p.join(tmp.path, 'out', 'x.png')),
        seed: 1,
      ),
      throwsA(
        isA<SdException>().having(
          (e) => e.message,
          'message',
          contains('missing sdxl_vae.safetensors'),
        ),
      ),
    );
    expect(File(p.join(tmp.path, 'args.txt')).existsSync(), isFalse);
  });

  test('builds sd-cli arguments for a clip from the Wan card', () {
    final wan = ImageCatalog.videoModels.first;
    final args = SdRun.videoArgs(
      AnimateRequest(
        model: wan,
        prompt: 'she smiles <lora:x:1>\nslowly',
        image: File('/pics/a.png'),
        frames: 49,
        shape: 'portrait',
      ),
      modelsDir: Directory('/m'),
      out: File('/o/x.webm'),
      seed: 7,
    );
    String after(String flag) => args[args.indexOf(flag) + 1];
    expect(args.take(2), ['-M', 'vid_gen']);
    expect(after('--diffusion-model'), '/m/Wan2.2-TI2V-5B-Q5_K_M.gguf');
    expect(after('--vae'), '/m/Wan2.2_VAE.safetensors');
    expect(after('--t5xxl'), '/m/umt5-xxl-encoder-Q5_K_M.gguf');
    expect(after('-i'), '/pics/a.png');
    expect(after('-p'), 'she smiles slowly');
    expect(after('--video-frames'), '49');
    // The 5B needs a bigger frame than the 14B: it packs 16 x 16 pixels
    // into each step, so at 384x512 it drew distorted, flashing bodies.
    expect(after('-W'), '640');
    expect(after('-H'), '896');
    expect(args, containsAll(['--offload-to-cpu', '--diffusion-fa']));
    expect(after('-o'), '/o/x.webm');
    for (var sec = VideoModel.shortest; sec <= VideoModel.longest; sec++) {
      expect((wan.framesFor(sec) - 1) % 4, 0, reason: 'Wan needs 4n + 1');
    }
    expect(wan.framesFor(2), 49);
    expect(wan.framesFor(15), 361);
    // Memory use follows what was measured on a 3090 at 384x512 (about
    // 10 GB for 2 s, 15 GB for 10 s) and grows with the frame's area.
    final area = 640 * 896 / (384 * 512);
    expect(wan.usedGb(2), closeTo(9.2 + 0.6 * 2 * area, 0.01));
    expect(wan.usedGb(10), closeTo(9.2 + 0.6 * 10 * area, 0.01));
    expect(wan.safeSeconds(24), 7);
    expect(wan.safeSeconds(12), 0);
    expect(wan.mostSeconds(16), 7);
    expect(wan.mostSeconds(8), 0);
    expect(args, isNot(contains('--vae-tiling')));
  });

  test('video models: LTX 2.5 makes a small clip, enlarges it, has sound', () {
    final ltx = ImageCatalog.videoModels.firstWhere((m) => m.id == 'ltx25');
    final args = SdRun.videoArgs(
      AnimateRequest(
        model: ltx,
        prompt: 'x',
        image: File('/a.png'),
        shape: 'portrait',
        frames: ltx.framesFor(5),
      ),
      modelsDir: Directory('/v'),
      out: File('/o/x.webm'),
      seed: 1,
    );
    String after(String f) => args[args.indexOf(f) + 1];
    expect(after('--diffusion-model'), endsWith('distilled-UD-Q4_K_XL.gguf'));
    expect(after('--llm'), '/v/gemma4-12b-with-proj-ltx-2.5-Q8_0.gguf');
    expect(after('--vae'), endsWith('video-vae-conv-bf16.safetensors'));
    expect(after('--audio-vae'), endsWith('audio-vae-bf16.safetensors'));
    // The upscaler is found by name, never passed as a file.
    expect(args.where((a) => a.contains('upscaler-x2-bf16-1.0.')), isEmpty);
    expect(after('--hires-upscalers-dir'), '/v');
    expect(
      after('--hires-upscaler'),
      'ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0',
    );
    expect(args, contains('--hires'));
    expect(after('--hires-sigmas'), '0.85,0.725,0.421875,0.0');
    expect(after('--sigmas'), startsWith('1.0,0.99375'));
    expect(args, isNot(contains('--steps')));
    expect(args, isNot(contains('--flow-shift')));
    expect(after('--cfg-scale'), '1.0');
    expect((int.parse(after('--video-frames')) - 1) % 8, 0);
    expect(ltx.framesFor(5), 121);
    expect(after('-W'), '384');
    expect(after('-H'), '512');
    expect(ltx.hasSound, isTrue);
    expect(ImageCatalog.videoModels.first.hasSound, isFalse);
    // The bf16 text encoder is squeezed once; the install check looks for
    // the squeezed file.
    final enc = ltx.files.firstWhere((f) => f.role == ImageFileRole.llm);
    expect(enc.sourceName, endsWith('bf16.safetensors'));
    expect(enc.fileName, endsWith('Q8_0.gguf'));
  });

  test('video models: MiniMax H3 uses 17k + 5 frames and the CPU random', () {
    final h3 = ImageCatalog.videoModels.firstWhere((m) => m.id == 'minimax-h3');
    final args = SdRun.videoArgs(
      AnimateRequest(
        model: h3,
        prompt: 'x',
        image: File('/a.png'),
        shape: 'portrait',
        frames: h3.framesFor(2),
      ),
      modelsDir: Directory('/v'),
      out: File('/o/x.webm'),
      seed: 1,
    );
    String after(String f) => args[args.indexOf(f) + 1];
    expect(h3.framesFor(2), 56);
    for (var sec = VideoModel.shortest; sec <= VideoModel.longest; sec++) {
      expect((h3.framesFor(sec) - 5) % 17, 0);
    }
    expect(after('--diffusion-model'), endsWith('fl2va_pruned-Q4_K_M.gguf'));
    expect(after('--llm'), endsWith('qwen3vl_32b_minimax_h3-Q4_K_M.gguf'));
    expect(after('--audio-vae'), endsWith('audio_vae_fp32.safetensors'));
    expect(after('--rng'), 'cpu');
    expect(args, containsAll(['--mmap', '--vae-tiling']));
    final lighter = ImageCatalog.videoModels.firstWhere(
      (m) => m.id == 'minimax-h3-lighter',
    );
    expect(lighter.sizeGb, lessThan(h3.sizeGb - 4));
    expect(after('--cfg-scale'), '1.0');
    expect(args, isNot(contains('--flow-shift')));
    expect(args, isNot(contains('--hires')));
    // Sizes must be multiples of 32.
    expect(int.parse(after('-W')) % 32, 0);
    expect(int.parse(after('-H')) % 32, 0);
    expect(h3.hasSound, isTrue);
  });

  test('video models: the 14B pair, and the human\'s own file', () async {
    final big = ImageCatalog.videoModels.firstWhere((m) => m.id == 'wan22-14b');
    final args = SdRun.videoArgs(
      AnimateRequest(model: big, prompt: 'x', image: File('/a.png')),
      modelsDir: Directory('/v'),
      out: File('/o/x.webm'),
      seed: 1,
    );
    String after(String f) => args[args.indexOf(f) + 1];
    expect(after('--diffusion-model'), endsWith('LowNoise-Q4_K_S.gguf'));
    expect(
      after('--high-noise-diffusion-model'),
      endsWith('HighNoise-Q4_K_S.gguf'),
    );
    expect(after('--steps'), '10');
    expect(after('--high-noise-steps'), '8');
    // Measured on a 3090: peaks near 15.8 GB for a 4 s clip.
    expect(big.usedGb(4), closeTo(15.8, 0.3));

    final dir = Directory.systemTemp.createTempSync('vox_video');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'my-finetune.gguf')).writeAsBytesSync([0]);
    final own = ImageCatalog.ownVideo(dir);
    expect(own.map((m) => m.name), ['my-finetune']);
    // Without Wan's VAE and text encoder beside it, it can't run yet.
    expect(ImageCatalog.availableVideo(dir), isEmpty);
    for (final f in ImageCatalog.videoModels.first.files.skip(1)) {
      File(p.join(dir.path, f.fileName)).writeAsBytesSync([0]);
    }
    expect(ImageCatalog.availableVideo(dir).map((m) => m.id), [
      'my-finetune.gguf',
    ]);
    // The catalog's own files are never taken for the human's.
    for (final f in ImageCatalog.videoModels.first.files) {
      File(p.join(dir.path, f.fileName)).writeAsBytesSync([0]);
    }
    expect(ImageCatalog.ownVideo(dir), hasLength(1));
  });

  test('own Anima finetunes draw with Anima\'s VAE and text encoder', () async {
    final s = AppSettings(modelsFolder: tmp.path);
    final dir = ImageCatalog.dirFor(s)..createSync(recursive: true);
    // A safetensors file: an 8-byte little-endian header length, then the
    // JSON header naming the tensors.
    void safetensors(String name, List<String> tensors) {
      final header = utf8.encode(
        jsonEncode({
          for (final t in tensors)
            t: {
              'dtype': 'F16',
              'shape': [1],
              'data_offsets': [0, 2],
            },
        }),
      );
      final n = header.length;
      File(p.join(dir.path, name)).writeAsBytesSync([
        for (var i = 0; i < 8; i++) (n >> (8 * i)) & 0xff,
        ...header,
        0,
        0,
      ]);
    }

    safetensors('SunstoneGemAnima.safetensors', [
      'model.diffusion_model.blocks.0.self_attn.q_proj.weight',
      'model.diffusion_model.llm_adapter.blocks.0.cross_attn.q_proj.weight',
    ]);
    safetensors('flux-dev.safetensors', [
      'model.diffusion_model.double_blocks.0.img_attn.qkv.weight',
    ]);
    safetensors('ponyMix.safetensors', [
      'model.diffusion_model.input_blocks.0.0.weight',
      'first_stage_model.decoder.conv_in.weight',
    ]);

    final own = {for (final m in ImageCatalog.own(dir)) m.id: m};
    final anima = own['SunstoneGemAnima.safetensors']!;
    expect(anima.files.map((f) => f.role.name), ['diffusion', 'vae', 'llm']);
    expect(anima.cantRun, isNull);
    expect(anima.sampler, ImageCatalog.byId('anima')!.sampler);
    final args = SdRun.args(
      DrawRequest(model: anima, prompt: '1girl'),
      modelsDir: dir,
      lorasDir: dir,
      out: File('/o/x.png'),
      seed: 1,
    );
    expect(args, isNot(contains('-m')));
    expect(
      args[args.indexOf('--diffusion-model') + 1],
      p.join(dir.path, 'SunstoneGemAnima.safetensors'),
    );
    expect(
      args[args.indexOf('--vae') + 1],
      p.join(dir.path, 'qwen_image_vae.safetensors'),
    );

    expect(own['flux-dev.safetensors']!.cantRun, contains('only the'));
    expect(own['ponyMix.safetensors']!.files.single.role.name, 'checkpoint');
    expect(ImageCatalog.available(dir).map((m) => m.id), [
      'ponyMix.safetensors',
      'SunstoneGemAnima.safetensors',
    ]);

    // Without Anima's parts it says where to get them, before sd-cli runs.
    final exe = await _fakeSdCli(tmp);
    await expectLater(
      SdRun.run(
        exe,
        DrawRequest(model: anima, prompt: '1girl'),
        modelsDir: dir,
        lorasDir: dir,
        out: File(p.join(tmp.path, 'out', 'x.png')),
        seed: 1,
      ),
      throwsA(
        isA<SdException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Anima Turbo or Anima Aesthetic'), contains('needs')),
        ),
      ),
    );
  });

  test('finds the human\'s own models and LoRAs', () async {
    final s = AppSettings(modelsFolder: tmp.path);
    final dir = ImageCatalog.dirFor(s)..createSync(recursive: true);
    File(p.join(dir.path, 'myMix.safetensors')).writeAsStringSync('x');
    // A part of a catalog model is not one of the human's own.
    File(p.join(dir.path, 'qwen_image_vae.safetensors')).writeAsStringSync('x');
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('x');
    final own = ImageCatalog.own(dir);
    expect(own.map((m) => m.id), ['myMix.safetensors']);
    expect(own.single.baseSize, 512, reason: 'a small file is an SD 1.5 model');
    expect(ImageCatalog.available(dir).single.own, isTrue);

    final loras = ImageCatalog.lorasFor(s)..createSync(recursive: true);
    File(p.join(loras.path, 'Watercolor.safetensors')).writeAsStringSync('x');
    File(
      p.join(loras.path, 'Watercolor.txt'),
    ).writeAsStringSync('Trigger: wtrcolor\nsoft painted look');
    File(p.join(loras.path, 'bad:name.safetensors')).writeAsStringSync('x');
    expect(ImageCatalog.loras(loras), [
      (name: 'Watercolor', note: 'Trigger: wtrcolor soft painted look'),
    ]);

    final text = aboutDrawing(
      s.copyWith(imageEngine: ImageEngineChoice.builtIn),
      ImageCatalog.available(dir),
      ImageCatalog.loras(loras),
    );
    expect(text, contains('- myMix (your usual one)'));
    expect(text, contains('- Watercolor: Trigger: wtrcolor'));
    expect(
      aboutDrawing(s, const [], const []),
      contains('can\'t draw pictures yet'),
    );
  });

  test('animating a picture makes a clip and keeps its first frame', () async {
    final folder = p.join(tmp.path, 'Mira');
    var settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
      modelsFolder: tmp.path,
      llmMode: LlmMode.external,
      imageEngine: ImageEngineChoice.builtIn,
    );
    final engine = ImageEngine(
      supportDir: tmp,
      runtime: RuntimeController(tmp),
      settings: () => settings,
      findExe: (_) async => await _fakeSdCli(tmp),
    );
    final still = File(p.join(tmp.path, 'fixture.png'));
    await _fakeSdCli(tmp);
    expect(await engine.animate(still, folder: folder), isNull);

    final dir = ImageCatalog.videoFor(settings)..createSync(recursive: true);
    for (final f in ImageCatalog.videoModels.first.files) {
      File(p.join(dir.path, f.fileName)).writeAsStringSync('x');
    }
    final job = (await engine.animate(still, folder: folder, prompt: 'wave'))!;
    final clip = await job.done;
    expect(p.extension(clip.path), '.webm');
    expect(p.basename(clip.path), startsWith('animated-'));
    expect(ImageEngine.thumbnailOf(clip).existsSync(), isTrue);
    final args = File(p.join(tmp.path, 'args.txt')).readAsLinesSync();
    expect(args, containsAll(['-M', 'vid_gen', 'wave']));
    settings = settings.copyWith(imageEngine: ImageEngineChoice.invoke);
    expect(await engine.animate(still, folder: folder), isNull);
  });

  test('the companion asks for a picture, and it is drawn after', () async {
    final folder = p.join(tmp.path, 'Mira');
    var settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
      modelsFolder: tmp.path,
      llmMode: LlmMode.external,
    );
    final runtime = RuntimeController(tmp);
    final exe = await _fakeSdCli(tmp);
    final engine = ImageEngine(
      supportDir: tmp,
      runtime: runtime,
      settings: () => settings,
      findExe: (_) async => exe,
    );
    final tools = DrawTools(settings: () => settings, engine: engine);
    Future<Map> draw(Map<String, Object?> args) async =>
        jsonDecode(await tools.call('draw_picture', args)) as Map;

    expect((await draw({'prompt': 'a cat'}))['error'], contains('off'));
    settings = settings.copyWith(imageEngine: ImageEngineChoice.builtIn);
    expect(
      (await draw({'prompt': 'a cat'}))['error'],
      contains('no picture model'),
    );

    final dir = ImageCatalog.dirFor(settings)..createSync(recursive: true);
    File(p.join(dir.path, 'mine.safetensors')).writeAsStringSync('x');
    expect(
      (await draw({'prompt': 'a cat', 'model': 'sdxl'}))['error'],
      contains('You have: mine'),
    );
    expect(
      (await draw({
        'prompt': 'a cat',
        'loras': [
          {'name': 'nope'},
        ],
      }))['error'],
      contains('no LoRA'),
    );

    final drawn = <File>[];
    engine.onDrawn = (job, file) async => drawn.add(file);
    final ok = await draw({'prompt': 'a cat', 'shape': 'portrait'});
    expect(ok['ok'], isTrue);
    expect(ok['drawing'], 'mine');
    while (engine.busy || engine.waiting > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(drawn.single.existsSync(), isTrue);
    expect(p.isWithin(p.join(folder, 'images'), drawn.single.path), isTrue);
    final args = File(p.join(tmp.path, 'args.txt')).readAsLinesSync();
    expect(args[args.indexOf('-m') + 1], p.join(dir.path, 'mine.safetensors'));
    expect(args[args.indexOf('-H') + 1], '640');
  });

  test(
    'a drawn picture lands in the chat, and the companion remembers it',
    () async {
      final requests = <Map>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requests.add(jsonDecode(await utf8.decodeStream(req)) as Map);
        req.response.headers.contentType = ContentType('text', 'event-stream');
        final delta = requests.length == 1
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'function': {
                      'name': 'draw_picture',
                      'arguments': '{"prompt": "a red fox in snow"}',
                    },
                  },
                ],
              }
            : {'content': 'Drawing it now!'};
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'delta': delta},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await req.response.close();
      });
      final db = await openAppDatabase(inMemoryDatabasePath);
      final folder = p.join(tmp.path, 'Mira');
      final services = AppServices(
        settings: SettingsStore(
          File(p.join(tmp.path, 'settings.json')),
          AppSettings(
            companionName: 'Mira',
            companionFolder: folder,
            modelsFolder: tmp.path,
            llmEndpoint: 'http://127.0.0.1:${server.port}/v1',
            llmMode: LlmMode.external,
            llmModel: 'mock',
            imageEngine: ImageEngineChoice.builtIn,
          ),
        ),
        db: db,
        dbKey: DatabaseKey(Directory.systemTemp),
        runtime: RuntimeController(tmp),
      );
      addTearDown(() async {
        await server.close(force: true);
        await db.close();
      });
      final dir = ImageCatalog.dirFor(services.settings.value)
        ..createSync(recursive: true);
      File(p.join(dir.path, 'mine.safetensors')).writeAsStringSync('x');
      final exe = await _fakeSdCli(tmp);
      final chat = ChatController(services);
      services.imageEngine
        ..findExe = ((_) async => exe)
        ..onDrawn = chat.addPicture;

      await chat.send('Draw me a fox?');
      expect(chat.error, isNull);
      expect(chat.toolNote, 'Drawing a picture');
      final system =
          ((requests.first['messages'] as List).first as Map)['content']
              as String;
      expect(system, contains('- mine (your usual one)'));
      while (chat.messages.last.via != 'picture') {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(chat.messages.last.content, startsWith('[image: images/drawn-'));

      await chat.send('What did you draw?');
      final history = requests.last['messages'] as List;
      expect(
        history.map((m) => (m as Map)['content']).join('\n'),
        contains('A picture you drew: images/drawn-'),
      );
      expect(
        history.map((m) => (m as Map)['content']).join('\n'),
        contains('What you asked for: a red fox in snow'),
      );
    },
  );

  test('builds an Invoke graph with LoRAs chained in', () {
    const xl = InvokeModel(
      key: 'k1',
      hash: 'h',
      name: 'Juggernaut',
      base: 'sdxl',
      type: 'main',
    );
    const lora = InvokeModel(
      key: 'l1',
      hash: 'h',
      name: 'Ink',
      base: 'sdxl',
      type: 'lora',
    );
    final g = InvokeClient.graph(
      model: xl,
      prompt: 'a fox',
      negative: 'text',
      width: 832,
      height: 1216,
      steps: 30,
      cfg: 6,
      scheduler: 'euler_a',
      seed: 7,
      loras: const [(lora: lora, weight: 0.7)],
    );
    final nodes = g['nodes'] as Map;
    expect((nodes['model'] as Map)['type'], 'sdxl_model_loader');
    expect((nodes['lora0'] as Map)['type'], 'sdxl_lora_loader');
    expect((nodes['lora0'] as Map)['weight'], 0.7);
    String? into(String node, String field) {
      for (final e in g['edges'] as List) {
        final d = (e as Map)['destination'] as Map;
        if (d['node_id'] == node && d['field'] == field) {
          return (e['source'] as Map)['node_id'] as String;
        }
      }
      return null;
    }

    expect(into('lora0', 'clip2'), 'model');
    expect(into('denoise', 'unet'), 'lora0');
    expect(into('positive', 'clip2'), 'lora0');
    expect(into('decode', 'vae'), 'model');
    expect(into('save', 'image'), 'decode');
  });

  test('draws through Invoke with what Invoke has', () async {
    final posted = <Map>[];
    final png = img.encodePng(img.Image(width: 4, height: 4));
    var polls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      final body = await utf8.decodeStream(req);
      Object? answer;
      if (path == '/api/v2/models/') {
        answer = {
          'models': req.uri.queryParameters['model_type'] == 'lora'
              ? [
                  {
                    'key': 'l1',
                    'hash': 'x',
                    'name': 'Ink',
                    'base': 'sd-1',
                    'type': 'lora',
                    'trigger_phrases': ['inkstyle'],
                  },
                ]
              : [
                  {
                    'key': 'm1',
                    'hash': 'x',
                    'name': 'Dreamshaper',
                    'base': 'sd-1',
                    'type': 'main',
                  },
                  {
                    'key': 'f1',
                    'hash': 'x',
                    'name': 'FLUX dev',
                    'base': 'flux',
                    'type': 'main',
                  },
                ],
        };
      } else if (path == '/api/v1/queue/default/enqueue_batch') {
        posted.add(jsonDecode(body) as Map);
        answer = {
          'item_ids': [5],
        };
      } else if (path == '/api/v1/queue/default/i/5') {
        answer = ++polls < 2
            ? {'status': 'in_progress'}
            : {
                'status': 'completed',
                'session': {
                  'results': {
                    'x': {
                      'type': 'image_output',
                      'image': {'image_name': 'abc.png'},
                    },
                  },
                },
              };
      } else if (path == '/api/v1/images/i/abc.png/full') {
        req.response.add(png);
        await req.response.close();
        return;
      }
      if (answer == null) req.response.statusCode = 404;
      req.response.write(jsonEncode(answer ?? {'detail': 'nope'}));
      await req.response.close();
    });

    final folder = p.join(tmp.path, 'Mira');
    final settings = AppSettings(
      companionName: 'Mira',
      companionFolder: folder,
      modelsFolder: tmp.path,
      llmMode: LlmMode.external,
      imageEngine: ImageEngineChoice.invoke,
      invokeUrl: 'http://127.0.0.1:${server.port}/',
    );
    final engine = ImageEngine(
      supportDir: tmp,
      runtime: RuntimeController(tmp),
      settings: () => settings,
    );
    final tools = DrawTools(settings: () => settings, engine: engine);
    final ok =
        jsonDecode(
              await tools.call('draw_picture', {
                'prompt': 'a lighthouse',
                'loras': [
                  {'name': 'ink', 'weight': 0.5},
                ],
              }),
            )
            as Map;
    expect(ok['ok'], isTrue, reason: '$ok');
    expect(ok['drawing'], 'Dreamshaper');
    expect(engine.available(settings).map((m) => m.name), ['Dreamshaper']);
    expect(
      aboutDrawing(
        settings,
        engine.available(settings),
        engine.lorasFor(settings),
      ),
      contains('- Ink: Trigger: inkstyle. For SD 1.5 models.'),
    );
    final drawn = <File>[];
    engine.onDrawn = (job, file) async => drawn.add(file);
    while (engine.busy || engine.waiting > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(drawn.single.readAsBytesSync(), png);
    final nodes = ((posted.single['batch'] as Map)['graph'] as Map)['nodes'];
    expect(((nodes as Map)['model'] as Map)['type'], 'main_model_loader');
    expect((nodes['lora0'] as Map)['weight'], 0.5);
    expect((nodes['noise'] as Map)['width'], 512);
  });
}

void clipPromptTests() {
  group('ClipPrompt', () {
    test('tidy strips labels, quotes and thinking', () {
      expect(
        ClipPrompt.tidy(
          '<think>hm</think>Prompt: "She laughs and puts on her sunglasses."',
        ),
        'She laughs and puts on her sunglasses.',
      );
      expect(ClipPrompt.tidy('ok'), isNull);
    });
    test('tidy cuts a long answer at a sentence', () {
      final long = '${'A sentence goes here. ' * 100}tail without end';
      final out = ClipPrompt.tidy(long)!;
      expect(out.length, lessThanOrEqualTo(ClipPrompt.maxChars));
      expect(out.endsWith('.'), isTrue);
    });
    test('instructions carry the length and the model', () {
      final short = ClipPrompt.instructions(
        detailed: false,
        seconds: 2,
        model: 'Wan 2.2 5B',
      );
      expect(short, contains('2 seconds'));
      expect(short, contains('one small action only'));
      expect(short, contains('Wan 2.2 5B'));
      expect(
        ClipPrompt.instructions(detailed: true, seconds: 12),
        contains('three or four actions'),
      );
    });
    test('the word target follows the model\'s prompt length', () {
      expect(
        ClipPrompt.instructions(detailed: false, chars: 300),
        contains('about 40 to 60 words'),
      );
      expect(
        ClipPrompt.instructions(detailed: true, chars: 1500),
        contains('about 200 to 300 words'),
      );
      expect(
        ClipPrompt.tidy('Ok then. ' * 100, max: 120)!.length,
        lessThanOrEqualTo(120),
      );
    });
    test('instructions differ by model style', () {
      expect(
        ClipPrompt.instructions(detailed: true),
        contains('double quotes'),
      );
      expect(ClipPrompt.instructions(detailed: false), contains('silent'));
    });
  });
}
