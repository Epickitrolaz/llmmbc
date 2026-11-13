/// App side hardware probe used when the core runtime is not available yet
/// (stub build / unsupported install). The core has its own probe; this one only
/// backs the degraded, UI-only mode so the Cluster screen still reflects the
/// real device.
library;

import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';

import 'platform_bridge.dart';

const int _mib = 1024 * 1024;

int _parseMemInfo(String key) {
  try {
    final lines = File('/proc/meminfo').readAsLinesSync();
    for (final line in lines) {
      if (!line.startsWith('$key:')) continue;
      final parts = line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.length < 2) continue;
      final kib = int.tryParse(parts[1]);
      if (kib != null) return kib * 1024;
    }
  } catch (_) {
    // Not Linux/Android or unreadable: caller falls back.
  }
  return 0;
}

String _cpuModel() {
  try {
    final lines = File('/proc/cpuinfo').readAsLinesSync();
    for (final key in const ['model name', 'Hardware', 'Processor', 'cpu model']) {
      for (final line in lines) {
        if (!line.toLowerCase().startsWith(key)) continue;
        final idx = line.indexOf(':');
        if (idx == -1) continue;
        final value = line.substring(idx + 1).trim();
        if (value.isNotEmpty) return value;
      }
    }
  } catch (_) {
    // ignore
  }
  return 'Unknown CPU';
}

String _detectArch() {
  final version = Platform.version;
  final match = RegExp(r'on "([^"]+)"').firstMatch(version);
  final raw = match?.group(1)?.toLowerCase() ?? '';
  if (raw.contains('arm64') || raw.contains('aarch64')) return 'arm64';
  if (raw.contains('arm')) return 'arm';
  if (raw.contains('x64') || raw.contains('x86_64')) return 'x64';
  if (raw.contains('ia32')) return 'ia32';
  if (raw.contains('riscv64')) return 'riscv64';
  return raw.isEmpty ? 'unknown' : raw;
}

Future<bool> _looksLikeEmulator() async {
  final reported = await PlatformBridge.deviceTags();
  if (reported.contains('emulator')) return true;
  for (final path in const ['/dev/qemu_pipe', '/dev/goldfish_pipe']) {
    try {
      if (File(path).existsSync()) return true;
    } catch (_) {
      // ignore
    }
  }
  return false;
}

List<String> _detectTags({required bool emulator}) {
  final tags = <String>[];
  if (emulator) tags.add('emulator');
  try {
    final model = File('/proc/device-tree/model');
    if (model.existsSync() && model.readAsStringSync().toLowerCase().contains('raspberry')) {
      tags.add('raspberry-pi');
    }
  } catch (_) {
    // ignore
  }
  try {
    final cgroup = File('/proc/1/cgroup');
    if (cgroup.existsSync() && cgroup.readAsStringSync().contains('docker')) {
      tags.add('docker');
    }
  } catch (_) {
    // ignore
  }
  return tags;
}

/// Reads RAM, CPU and GPU information of this device without the core runtime.
Future<HardwareProfile> probeLocalHardware({
  PlatformHooks hooks = const PlatformHooks(),
  List<String> extraTags = const [],
}) async {
  final total = _parseMemInfo('MemTotal');
  final available = _parseMemInfo('MemAvailable');
  final emulator = await _looksLikeEmulator();

  final gpus = <GpuInfo>[];
  try {
    final renderer = await hooks.gpuRenderer?.call();
    if (renderer != null && renderer.trim().isNotEmpty) {
      gpus.add(GpuInfo(name: renderer.trim(), backend: GpuBackend.other));
    }
  } catch (_) {
    // GPU name is optional.
  }

  final tags = {..._detectTags(emulator: emulator), ...extraTags}.toList();

  return HardwareProfile(
    os: Platform.operatingSystem,
    arch: _detectArch(),
    cpuModel: _cpuModel(),
    cpuCores: Platform.numberOfProcessors,
    totalRamBytes: total > 0 ? total : 4 * 1024 * _mib,
    availableRamBytes: available > 0 ? available : (total > 0 ? total ~/ 2 : 2 * 1024 * _mib),
    gpus: gpus,
    tags: tags,
  );
}
