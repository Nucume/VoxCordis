import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the models let go after a quiet minute, never mid-reply', () async {
    final tmp = await Directory.systemTemp.createTemp('idle');
    addTearDown(() => tmp.delete(recursive: true));
    final runtime = RuntimeController(tmp);
    const off = AppSettings(modelPath: '/nowhere.gguf');
    final on = off.copyWith(freeGpuWhenIdle: true);

    runtime.touch(off);
    expect(runtime.idleUnloadPending, isFalse);
    runtime.touch(on);
    expect(runtime.idleUnloadPending, isTrue);

    // A reply (or two at once) keeps them loaded until the last one ends.
    runtime
      ..hold()
      ..hold();
    expect(runtime.idleUnloadPending, isFalse);
    runtime.release(on);
    expect(runtime.idleUnloadPending, isFalse);
    runtime.release(on);
    expect(runtime.idleUnloadPending, isTrue);

    // Turning it off, or a server-hosted brain, stops the countdown.
    runtime.touch(off);
    expect(runtime.idleUnloadPending, isFalse);
    runtime.touch(on.copyWith(llmMode: LlmMode.external));
    expect(runtime.idleUnloadPending, isFalse);
  });

  test('the setting is saved', () {
    final s = AppSettings.fromJson(
      const AppSettings(freeGpuWhenIdle: true).toJson(),
    );
    expect(s.freeGpuWhenIdle, isTrue);
    expect(AppSettings.fromJson(const {}).freeGpuWhenIdle, isFalse);
  });
}
