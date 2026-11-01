import 'package:flutter/services.dart' show MethodChannel;

/// Windows' own answers, from the runner (windows/runner/system_info.cpp):
/// the registry and the shell are asked through their APIs, not through
/// other programs.
class WindowsNative {
  const WindowsNative._();

  static const _channel = MethodChannel('voxcordis/system');

  /// Display adapters and their video memory in bytes (0 when unknown).
  static Future<List<({String name, int bytes})>> displayAdapters() async {
    final list = await _channel.invokeListMethod<Map>('displayAdapters');
    return [
      for (final m in list ?? const <Map>[])
        if (m['name'] is String)
          (name: m['name'] as String, bytes: (m['bytes'] as int?) ?? 0),
    ];
  }

  /// "desktop", "documents", "downloads", "music", "pictures" or "videos";
  /// null when Windows has no answer.
  static Future<String?> knownFolder(String name) async {
    final path = await _channel.invokeMethod<String>('knownFolder', {
      'name': name,
    });
    return path == null || path.isEmpty ? null : path;
  }

  /// Starts VoxCordis with [command] at login, or no longer when null.
  static Future<void> setLoginItem(String? command) =>
      _channel.invokeMethod<bool>('setLoginItem', {'command': command ?? ''});

  /// A DWORD under HKEY_CURRENT_USER, or null when it isn't there.
  static Future<int?> userDword(String key, String name) =>
      _channel.invokeMethod<int>('userDword', {'key': key, 'name': name});

  /// The file name of the program running as [pid] ("llama-server.exe"), or
  /// an empty text when there is none.
  static Future<String> processName(int pid) async =>
      await _channel.invokeMethod<String>('processName', {'pid': pid}) ?? '';

  /// Opens [target] the way double-clicking it would.
  static Future<void> open(String target) =>
      _channel.invokeMethod<bool>('open', {'target': target});
}
