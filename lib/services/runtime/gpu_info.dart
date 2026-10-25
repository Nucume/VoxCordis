import 'dart:io';
import 'dart:math';

/// What we could find out about the graphics card, to recommend a model.
class GpuInfo {
  const GpuInfo({this.name, this.memoryGb, this.shared = false});

  static const unknown = GpuInfo();

  final String? name;

  /// Memory the model can use: dedicated VRAM, or on Apple silicon the part
  /// of the shared memory macOS lets the GPU have.
  final double? memoryGb;

  /// Apple silicon: CPU and GPU share one pool of memory.
  final bool shared;

  bool get known => memoryGb != null;

  String get label {
    final gb = memoryGb == null ? '' : ' (${memoryGb!.round()} GB)';
    return '${name ?? 'Graphics card'}$gb';
  }

  /// Best guess, never throws; unknown when nothing answers.
  static Future<GpuInfo> detect() async {
    try {
      if (Platform.isMacOS) return await _mac();
      final nvidia = await _nvidiaSmi();
      if (nvidia != null) return nvidia;
      if (Platform.isLinux) return await _linuxDrm() ?? unknown;
      if (Platform.isWindows) return await _windowsRegistry() ?? unknown;
    } catch (_) {
      // Fall through: no recommendation is better than a wrong one.
    }
    return unknown;
  }

  static Future<GpuInfo?> _nvidiaSmi() async {
    try {
      final r = await Process.run('nvidia-smi', [
        '--query-gpu=name,memory.total',
        '--format=csv,noheader,nounits',
      ]);
      if (r.exitCode != 0) return null;
      return parseNvidiaSmi(r.stdout as String);
    } on ProcessException {
      return null; // not installed
    }
  }

  /// `NVIDIA GeForce RTX 3060, 12288` per line (MiB); takes the largest.
  static GpuInfo? parseNvidiaSmi(String out) {
    GpuInfo? best;
    for (final line in out.split('\n')) {
      final parts = line.split(',');
      if (parts.length < 2) continue;
      final mib = double.tryParse(parts.last.trim());
      if (mib == null) continue;
      final gb = mib / 1024;
      if (best == null || gb > best.memoryGb!) {
        best = GpuInfo(name: parts.first.trim(), memoryGb: gb);
      }
    }
    return best;
  }

  /// AMD (and some Intel Arc) cards report VRAM through the DRM driver.
  static Future<GpuInfo?> _linuxDrm() async {
    final drm = Directory('/sys/class/drm');
    if (!await drm.exists()) return null;
    GpuInfo? best;
    await for (final e in drm.list()) {
      final name = e.path.split('/').last;
      if (!RegExp(r'^card\d+$').hasMatch(name)) continue;
      final vram = File('${e.path}/device/mem_info_vram_total');
      if (!await vram.exists()) continue;
      final bytes = int.tryParse((await vram.readAsString()).trim());
      // Integrated GPUs report a small carve-out; ignore those.
      if (bytes == null || bytes < 2 * 1024 * 1024 * 1024) continue;
      final gb = bytes / (1024 * 1024 * 1024);
      if (best == null || gb > best.memoryGb!) {
        best = GpuInfo(name: await _drmName(e.path), memoryGb: gb);
      }
    }
    return best;
  }

  static Future<String?> _drmName(String card) async {
    final f = File('$card/device/product_name');
    if (await f.exists()) return (await f.readAsString()).trim();
    return null;
  }

  /// Display adapters record their real VRAM size (64-bit) in the registry;
  /// WMI's AdapterRAM caps at 4 GB.
  static Future<GpuInfo?> _windowsRegistry() async {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r"Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -ErrorAction SilentlyContinue | "
          r"ForEach-Object { '{0}|{1}' -f $_.DriverDesc, $_.'HardwareInformation.qwMemorySize' }",
    ]);
    if (r.exitCode != 0) return null;
    return parseWindowsRegistry(r.stdout as String);
  }

  /// `AMD Radeon RX 6700 XT|12868124672` per line; takes the largest.
  static GpuInfo? parseWindowsRegistry(String out) {
    GpuInfo? best;
    for (final line in out.split('\n')) {
      final parts = line.trim().split('|');
      if (parts.length != 2) continue;
      final bytes = int.tryParse(parts[1].trim());
      if (bytes == null || bytes <= 0) continue;
      final gb = bytes / (1024 * 1024 * 1024);
      if (best == null || gb > best.memoryGb!) {
        best = GpuInfo(name: parts[0].trim(), memoryGb: gb);
      }
    }
    return best;
  }

  static Future<GpuInfo> _mac() async {
    final r = await Process.run('sysctl', ['-n', 'hw.memsize']);
    final bytes = int.tryParse((r.stdout as String).trim());
    if (bytes == null) return unknown;
    final ram = bytes / (1024 * 1024 * 1024);
    // macOS lets Metal use roughly two thirds to three quarters of RAM.
    return GpuInfo(
      name: 'Apple silicon, shared memory',
      memoryGb: ram * (ram >= 32 ? 0.75 : 0.66),
      shared: true,
    );
  }
}

/// Rough graphics memory a model needs at a given memory span: the weights
/// plus about 1 GB per 8k tokens of conversation beyond the first 8k.
double estimateNeedGb({required double baseGb, required int contextSize}) =>
    baseGb + max(0, contextSize - 8192) / 8192;

/// The longest memory span that still fits a card of [cardGb] with a model
/// needing [baseGb] at 8k, keeping half a gigabyte for the desktop. Normal
/// (8k) when the card is unknown or nothing longer fits.
int suggestContextSize({required double baseGb, required double? cardGb}) {
  if (cardGb == null) return 8192;
  for (final ctx in const [32768, 16384]) {
    if (estimateNeedGb(baseGb: baseGb, contextSize: ctx) <= cardGb - 0.5) {
      return ctx;
    }
  }
  return 8192;
}
