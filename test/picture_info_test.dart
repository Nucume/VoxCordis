import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:companion/data/settings.dart';
import 'package:companion/features/images/draw_presets.dart';
import 'package:companion/services/images/image_catalog.dart';
import 'package:companion/services/images/picture_info.dart';
import 'package:companion/services/images/sd_runtime.dart';

void main() {
  final model = ImageCatalog.models.first;

  test('a picture keeps what it was drawn with, beside it', () async {
    final dir = Directory.systemTemp.createTempSync('picture_info');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pic = File(p.join(dir.path, 'images', 'drawn-1.png'))
      ..createSync(recursive: true);
    final info = PictureInfo.of(
      DrawRequest(
        model: model,
        prompt: '1girl, black hair',
        negative: 'blurry',
        shape: 'portrait',
        loras: const [(name: 'grain', weight: 0.8)],
        steps: 30,
        sampler: 'dpm++2m',
        scheduler: 'karras',
      ),
      1234,
    );
    expect(info.seed, 1234);
    expect(info.steps, 30);
    expect(info.cfg, model.cfg);
    expect(info.sampler, SdRun.samplers['dpm++2m']);
    expect(info.scheduler, SdRun.schedulers['karras']);
    expect(
      (info.width, info.height),
      (model.sizeFor('portrait').width, model.sizeFor('portrait').height),
    );
    await info.writeFor(pic);
    // Hidden, so the gallery doesn't list it.
    expect(
      File(
        p.join(dir.path, 'images', '.info', 'drawn-1.png.json'),
      ).existsSync(),
      isTrue,
    );
    final back = (await PictureInfo.read(pic))!;
    expect(back.text, info.text);
    expect(back.text, contains('Prompt: 1girl, black hair'));
    expect(back.text, contains('Seed: 1234'));
    expect(back.text, contains('LoRAs: grain 0.8'));

    final moved = File(p.join(dir.path, 'portrait.png'))..createSync();
    await PictureInfo.move(pic, moved);
    expect(await PictureInfo.read(pic), isNull);
    expect((await PictureInfo.read(moved))!.seed, 1234);
    await PictureInfo.deleteFor(moved);
    expect(await PictureInfo.read(moved), isNull);
  });

  test('presets are kept by name, newest first', () async {
    final dir = Directory.systemTemp.createTempSync('presets');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SettingsStore(
      File(p.join(dir.path, 'settings.json')),
      const AppSettings(),
    );
    await saveDrawPreset(
      store,
      const DrawPreset(name: 'Neon', prompt: 'neon city', negative: 'blurry'),
    );
    await saveDrawPreset(
      store,
      const DrawPreset(name: 'Forest', prompt: 'misty forest'),
    );
    await saveDrawPreset(
      store,
      const DrawPreset(name: 'neon', prompt: 'neon city at night'),
    );
    final presets = store.value.draw.presets;
    expect(presets.map((p) => p.name), ['neon', 'Forest']);
    final json = DrawPanelPrefs.fromJson(store.value.draw.toJson());
    expect(json.presets.map((p) => p.prompt), [
      'neon city at night',
      'misty forest',
    ]);
    expect(
      presetNameFor('portrait, upper body, solo, 1girl, black hair'),
      'portrait, upper body, solo, 1girl,',
    );
  });
}
