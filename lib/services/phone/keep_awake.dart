import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keeps the computer from going to sleep while a phone is connected, so
/// the phone isn't cut off mid-story. The screen may still turn off.
///
/// - **Linux:** a `systemd-inhibit` sleep lock, held by a waiting child
///   process and let go by ending it.
/// - **Windows:** `SetThreadExecutionState`, asked on the app's own thread.
/// - **macOS:** `caffeinate -i`.
class KeepAwake {
  Process? _lock;
  bool _on = false;
  bool get on => _on;

  Future<void> set(bool on) async {
    if (on == _on) return;
    _on = on;
    try {
      if (Platform.isWindows) {
        _windows(on);
      } else if (on) {
        _lock = await _start();
      } else {
        _lock?.kill();
        _lock = null;
      }
    } on Object catch (e) {
      debugPrint('Keeping the computer awake didn\'t work: $e');
    }
  }

  static Future<Process?> _start() async {
    if (Platform.isLinux) {
      return Process.start('systemd-inhibit', [
        '--what=sleep:idle',
        '--who=VoxCordis',
        '--why=A phone is using VoxCordis',
        '--mode=block',
        'sleep',
        'infinity',
      ]);
    }
    if (Platform.isMacOS) {
      return Process.start('caffeinate', ['-i', '-w', '$pid']);
    }
    return null;
  }

  static const _continuous = 0x80000000;
  static const _systemRequired = 0x00000001;

  static void _windows(bool on) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final set = kernel32
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    set(on ? _continuous | _systemRequired : _continuous);
  }
}
