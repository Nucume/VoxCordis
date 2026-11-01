import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../folder_service.dart';

/// Linux and macOS system calls, made directly instead of through the
/// programs (`chmod`, `id`, `ps`, `xdg-user-dir`) that wrap them.
class PosixNative {
  const PosixNative._();

  /// `chmod +x`: adds the execute bits wherever the read bits are set.
  /// Returns false when the call isn't available or fails.
  static bool makeExecutable(String path) {
    try {
      final mode = File(path).statSync().mode;
      final withExec = mode | ((mode & 0x124) >> 2); // r bits → x bits
      final chmod = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Uint32),
            int Function(Pointer<Utf8>, int)
          >('chmod');
      final c = path.toNativeUtf8();
      try {
        return chmod(c, withExec & 0xFFF) == 0;
      } finally {
        malloc.free(c);
      }
    } on Object {
      return false;
    }
  }

  /// Whether this process runs as root (`getuid() == 0`).
  static bool isRoot() {
    try {
      return DynamicLibrary.process()
              .lookupFunction<Uint32 Function(), int Function()>('getuid')() ==
          0;
    } on Object {
      return false;
    }
  }

  /// The name of the program running as [pid] on macOS (`proc_name`), or an
  /// empty text.
  static String macProcessName(int pid) {
    try {
      final procName = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Uint32),
            int Function(int, Pointer<Utf8>, int)
          >('proc_name');
      final buf = malloc<Uint8>(256).cast<Utf8>();
      try {
        final n = procName(pid, buf, 256);
        return n > 0 ? buf.toDartString() : '';
      } finally {
        malloc.free(buf);
      }
    } on Object {
      return '';
    }
  }

  /// A folder from `~/.config/user-dirs.dirs`, e.g. `XDG_DOWNLOAD_DIR`, the
  /// file `xdg-user-dir` reads; null when it names none.
  static String? xdgUserDir(String name, {String? configFile, String? home}) {
    try {
      final h = home ?? homeDir;
      final file = File(
        configFile ??
            p.join(
              Platform.environment['XDG_CONFIG_HOME'] ?? p.join(h, '.config'),
              'user-dirs.dirs',
            ),
      );
      if (!file.existsSync()) return null;
      for (final line in file.readAsLinesSync()) {
        final m = RegExp(
          '^\\s*XDG_${name}_DIR\\s*=\\s*"(.*)"\\s*\$',
        ).firstMatch(line);
        if (m == null) continue;
        final dir = m.group(1)!.replaceAll(r'$HOME', h);
        return dir.isEmpty ? null : dir;
      }
    } on Object {
      // Unreadable: the usual place.
    }
    return null;
  }
}
