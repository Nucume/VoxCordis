import 'package:companion/services/runtime/gpu_info.dart';
import 'package:companion/services/runtime/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads nvidia-smi output', () {
    final g = GpuInfo.parseNvidiaSmi(
      'NVIDIA GeForce GTX 1650, 4096\nNVIDIA GeForce RTX 3060, 12288\n',
    )!;
    expect(g.name, 'NVIDIA GeForce RTX 3060');
    expect(g.memoryGb, 12);
  });

  test('picks the Windows display adapter with the most memory', () {
    final g = GpuInfo.fromAdapters([
      (name: 'Intel(R) UHD Graphics', bytes: 0),
      (name: 'AMD Radeon RX 6700 XT', bytes: 12868124672),
      (name: 'Small GPU', bytes: 1073741824),
    ])!;
    expect(g.name, 'AMD Radeon RX 6700 XT');
    expect(g.memoryGb!.round(), 12);
  });

  test('recommends the biggest model that fits', () {
    String? pick(double? gb) =>
        ModelCatalog.recommendFor(GpuInfo(memoryGb: gb))?.id;
    expect(pick(null), isNull);
    expect(pick(4), 'qwen3-4b'); // nothing fits: smallest
    expect(pick(6), 'qwen3-4b');
    expect(pick(7), 'qwen3-4b'); // needs some headroom
    expect(pick(8), 'qwen3-8b');
    expect(pick(10), 'qwen3-8b'); // never the one-trick vision model
    expect(pick(12), 'gemma-4-12b');
    expect(pick(16), 'gemma-4-12b');
    expect(pick(24), 'qwen3.8-27b');
    // Never the huge, uncensored or archived ones.
    expect(pick(200), 'qwen3.8-27b');
  });

  test('archived models are still recognised', () {
    final old = ModelCatalog.models.where((m) => m.archived).toList();
    expect(
      old.map((m) => m.id),
      containsAll(['rocinante-12b', 'mistral-nemo-12b']),
    );
    for (final m in old) {
      expect(ModelCatalog.forPath('/models/${m.file}'), m);
    }
  });

  test('split models fetch every part, the loaded one last', () {
    final glm = ModelCatalog.models.firstWhere((m) => m.huge);
    expect(glm.allFiles, hasLength(3));
    expect(glm.allFiles.last, glm.file);
    expect(glm.allFiles.last, endsWith('-00001-of-00003.gguf'));
    expect(
      glm.urlFor(glm.file).toString(),
      startsWith('https://huggingface.co/huihui-ai/'),
    );
  });

  test('longer memory spans need more memory', () {
    expect(estimateNeedGb(baseGb: 8, contextSize: 8192), 8);
    expect(estimateNeedGb(baseGb: 8, contextSize: 32768), 11);
    expect(estimateNeedGb(baseGb: 8, contextSize: 4096), 8);
  });

  test('picks the longest memory span the card fits', () {
    // Qwen3 8B needs about 7 GB at 8k.
    expect(suggestContextSize(baseGb: 7, cardGb: 8), 8192);
    expect(suggestContextSize(baseGb: 7, cardGb: 9), 16384);
    expect(suggestContextSize(baseGb: 7, cardGb: 12), 32768);
    expect(suggestContextSize(baseGb: 10, cardGb: 8), 8192);
    expect(suggestContextSize(baseGb: 7, cardGb: null), 8192);
  });
}
