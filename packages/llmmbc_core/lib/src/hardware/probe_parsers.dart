/// Pure text parsers used by the hardware probe.
///
/// Everything here is a pure function over captured text so that the probe can be exercised
/// against fixtures for every supported platform (x86 Linux, Raspberry Pi, Android emulator,
/// cgroup-limited containers, NVIDIA/ROCm, macOS and Windows) without touching the host.
library;

import 'dart:convert';

import '../models.dart';

/// Total/available memory extracted from `/proc/meminfo` (or an equivalent source).
class MemInfo {
  final int totalBytes;
  final int availableBytes;
  const MemInfo({required this.totalBytes, required this.availableBytes});

  @override
  String toString() => 'MemInfo(total: $totalBytes, available: $availableBytes)';
}

// ---------------------------------------------------------------------------
// Linux / Android (/proc)
// ---------------------------------------------------------------------------

/// Parses `/proc/meminfo`.
///
/// Uses `MemAvailable` when present, otherwise approximates it from
/// `MemFree + Buffers + Cached (+ SReclaimable - Shmem)`.
MemInfo? parseMeminfo(String text) {
  final values = <String, int>{};
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim();
    final rest = line.substring(colon + 1).trim();
    final match = RegExp(r'^(\d+)').firstMatch(rest);
    if (match == null) continue;
    final value = int.tryParse(match.group(1)!);
    if (value == null) continue;
    values[key] = value;
  }

  final totalKb = values['MemTotal'];
  if (totalKb == null || totalKb <= 0) return null;

  int availableKb;
  final memAvailable = values['MemAvailable'];
  if (memAvailable != null) {
    availableKb = memAvailable;
  } else {
    availableKb = (values['MemFree'] ?? 0) +
        (values['Buffers'] ?? 0) +
        (values['Cached'] ?? 0) +
        (values['SReclaimable'] ?? 0) -
        (values['Shmem'] ?? 0);
  }
  if (availableKb < 0) availableKb = 0;
  if (availableKb > totalKb) availableKb = totalKb;

  return MemInfo(totalBytes: totalKb * 1024, availableBytes: availableKb * 1024);
}

/// Parses a cgroup memory limit. Returns null for `max`, empty, unparsable or
/// "unlimited" values (cgroup v1 uses a huge sentinel such as `9223372036854771712`).
int? parseCgroupMemoryLimit(String text) {
  final value = text.trim();
  if (value.isEmpty || value == 'max') return null;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) return null;
  // >= 2^60 is the conventional "no limit" marker.
  if (parsed >= (1 << 60)) return null;
  return parsed;
}

/// Returns the lower of [mem] and the cgroup limit, clamping availability to what is left
/// under the limit.
MemInfo applyCgroupLimit(MemInfo mem, int? limit, int? currentUsage) {
  if (limit == null || limit <= 0 || limit >= mem.totalBytes) return mem;
  var available = mem.availableBytes;
  if (currentUsage != null && currentUsage >= 0) {
    final remaining = limit - currentUsage;
    if (remaining < available) available = remaining;
  }
  if (available < 0) available = 0;
  if (available > limit) available = limit;
  return MemInfo(totalBytes: limit, availableBytes: available);
}

/// CPU model from `/proc/cpuinfo`. x86 exposes `model name`, ARM boards use
/// `Model` (Raspberry Pi) or `Hardware`, older ARM kernels use `Processor`.
String? parseCpuModel(String text) {
  final values = <String, String>{};
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim();
    // Keep the first occurrence; cpuinfo repeats blocks per core.
    values.putIfAbsent(key, () => line.substring(colon + 1).trim());
  }
  for (final key in const ['model name', 'Model', 'Hardware', 'Processor', 'cpu model', 'cpu']) {
    final value = values[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Number of `processor` entries in `/proc/cpuinfo`.
int? parseCpuCoreCount(String text) {
  final matches = RegExp(r'^processor\s*:', multiLine: true).allMatches(text);
  return matches.isEmpty ? null : matches.length;
}

/// `/proc/device-tree/model`, with the trailing NUL padding stripped.
String normalizeDeviceTreeModel(String? raw) {
  if (raw == null) return '';
  return raw.replaceAll('\u0000', '').trim();
}

bool isRaspberryPiModel(String model) => model.toLowerCase().contains('raspberry pi');

/// True when a cgroup file or `/.dockerenv` indicates a container runtime.
bool detectContainer(String cgroupText, {bool dockerenvPresent = false}) {
  if (dockerenvPresent) return true;
  final lower = cgroupText.toLowerCase();
  if (lower.contains('docker') ||
      lower.contains('kubepods') ||
      lower.contains('containerd') ||
      lower.contains('libpod') ||
      lower.contains('lxc')) {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Architecture
// ---------------------------------------------------------------------------

/// Normalises `uname -m` / `PROCESSOR_ARCHITECTURE` / Dart ABI names.
String normalizeArch(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'x86_64':
    case 'x86-64':
    case 'amd64':
      return 'x64';
    case 'aarch64':
    case 'arm64':
    case 'arm64-v8a':
      return 'arm64';
    case 'armv7l':
    case 'armv7':
    case 'armv6l':
    case 'arm':
    case 'armeabi-v7a':
      return 'arm';
    case 'i386':
    case 'i486':
    case 'i586':
    case 'i686':
    case 'x86':
    case 'ia32':
      return 'ia32';
  }
  final lower = raw.trim().toLowerCase();
  if (lower.contains('arm64') || lower.contains('aarch64')) return 'arm64';
  if (lower.contains('x64') || lower.contains('x86_64')) return 'x64';
  if (lower.contains('arm')) return 'arm';
  if (lower.contains('ia32') || lower.contains('x86')) return 'ia32';
  return '';
}

// ---------------------------------------------------------------------------
// GPUs
// ---------------------------------------------------------------------------

/// Parses `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits`.
List<GpuInfo> parseNvidiaSmi(String text) {
  final gpus = <GpuInfo>[];
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.toLowerCase().startsWith('name')) continue;
    final comma = line.lastIndexOf(',');
    if (comma <= 0) continue;
    final name = line.substring(0, comma).trim();
    final mib = int.tryParse(line.substring(comma + 1).trim());
    if (name.isEmpty) continue;
    gpus.add(GpuInfo(
      name: name,
      backend: GpuBackend.cuda,
      vramBytes: (mib == null || mib < 0) ? 0 : mib * 1024 * 1024,
    ));
  }
  return gpus;
}

/// Parses `rocm-smi --showmeminfo vram --csv` output (or the `--showproductname`
/// variant that puts the product name in the second column).
List<GpuInfo> parseRocmSmi(String text) {
  final gpus = <GpuInfo>[];
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final lower = line.toLowerCase();
    if (lower.startsWith('device') || lower.contains('total memory (b)')) continue;
    final cols = line.split(',').map((c) => c.trim()).toList();
    if (cols.first.toLowerCase() != 'card0' &&
        !RegExp(r'^card\d+$').hasMatch(cols.first.toLowerCase())) {
      continue;
    }
    int? bytes;
    String? name;
    for (final col in cols.skip(1)) {
      final value = int.tryParse(col);
      if (value != null) {
        // The first large numeric column is the total VRAM byte count; the second
        // one (if present) is the amount in use.
        if (bytes == null && value >= (1 << 20)) bytes = value;
      } else if (col.isNotEmpty && !col.toLowerCase().contains('gpu')) {
        name ??= col;
      }
    }
    if (bytes == null) continue;
    gpus.add(GpuInfo(
      name: name ?? 'AMD GPU (${cols.first})',
      backend: GpuBackend.rocm,
      vramBytes: bytes,
    ));
  }
  return gpus;
}

/// `mem_info_vram_total` from sysfs: a plain byte count.
int? parseSysfsVramTotal(String text) {
  final value = int.tryParse(text.trim());
  return (value == null || value <= 0) ? null : value;
}

/// Builds a ROCm GPU entry for one `/sys/class/drm/cardN` directory.
GpuInfo rocmGpuFromSysfs(String card, int vramBytes, {String? productName}) => GpuInfo(
      name: (productName == null || productName.trim().isEmpty)
          ? 'AMD GPU ($card)'
          : productName.trim(),
      backend: GpuBackend.rocm,
      vramBytes: vramBytes,
    );

/// Guesses the compute backend for an Android GL/Vulkan renderer string.
///
/// Android GPUs share system RAM (unified memory), so VRAM is always reported as 0.
GpuBackend guessAndroidGpuBackend(String renderer) {
  final lower = renderer.toLowerCase();
  if (lower.contains('vulkan')) return GpuBackend.vulkan;
  return GpuBackend.opencl;
}

/// Parses a `system_profiler SPDisplaysDataType` capture for the GPU/SoC name.
String? parseSystemProfilerGpu(String text) {
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.startsWith('Chipset Model:')) {
      final value = line.substring('Chipset Model:'.length).trim();
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// macOS
// ---------------------------------------------------------------------------

/// Parses `sysctl -n hw.memsize` (a bare number) or `sysctl hw.memsize` (`key: value`).
int? parseSysctlInt(String text) {
  int? result;
  for (final match in RegExp(r'(\d+)\s*$', multiLine: true).allMatches(text)) {
    result = int.tryParse(match.group(1)!) ?? result;
  }
  return (result == null || result <= 0) ? null : result;
}

/// Parses `sysctl -n machdep.cpu.brand_string` / `hw.model`.
String? parseSysctlString(String text) {
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    final value = colon >= 0 ? line.substring(colon + 1).trim() : line;
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Estimated available memory from `vm_stat`.
///
/// Available = free + inactive + speculative + purgeable pages. The page size is taken from
/// the header line (`page size of 16384 bytes`, 4096 on Intel).
int? parseVmStat(String text) {
  final pageSizeMatch = RegExp(r'page size of (\d+) bytes').firstMatch(text);
  final pageSize = int.tryParse(pageSizeMatch?.group(1) ?? '') ?? 4096;
  final pages = <String, int>{};
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim();
    final match = RegExp(r'^(\d+)').firstMatch(line.substring(colon + 1).trim());
    if (match == null) continue;
    final value = int.tryParse(match.group(1)!);
    if (value != null) pages[key] = value;
  }
  if (pages.isEmpty) return null;
  final totalPages = (pages['Pages free'] ?? 0) +
      (pages['Pages inactive'] ?? 0) +
      (pages['Pages speculative'] ?? 0) +
      (pages['Pages purgeable'] ?? 0);
  if (totalPages <= 0) return null;
  return totalPages * pageSize;
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

/// Parses `wmic OS get TotalVisibleMemorySize,FreePhysicalMemory /format:list`
/// (`Key=Value` lines, sizes in KiB).
MemInfo? parseWmicMemory(String text) {
  final values = _parseWmicList(text);
  final totalKb = values['TotalVisibleMemorySize'];
  final freeKb = values['FreePhysicalMemory'];
  if (totalKb == null || totalKb <= 0) return null;
  final available = (freeKb ?? totalKb) * 1024;
  return MemInfo(
    totalBytes: totalKb * 1024,
    availableBytes: available > totalKb * 1024 ? totalKb * 1024 : available,
  );
}

Map<String, int> _parseWmicList(String text) {
  final values = <String, int>{};
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    final value = int.tryParse(line.substring(eq + 1).trim());
    if (value != null) values[key] = value;
  }
  return values;
}

List<Map<String, dynamic>> _decodeWin32Json(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is List) {
      return [for (final item in decoded) if (item is Map<String, dynamic>) item];
    }
    if (decoded is Map<String, dynamic>) return [decoded];
  } on FormatException {
    // Not JSON – caller falls back to wmic parsing.
  }
  return const [];
}

/// Parses `Get-CimInstance Win32_OperatingSystem | ConvertTo-Json -Compress`.
/// Sizes are in KiB.
MemInfo? parseWindowsOperatingSystemJson(String text) {
  final items = _decodeWin32Json(text);
  if (items.isEmpty) return null;
  final item = items.first;
  final totalKb = _asInt(item['TotalVisibleMemorySize']);
  final freeKb = _asInt(item['FreePhysicalMemory']);
  if (totalKb == null || totalKb <= 0) return null;
  final available = (freeKb ?? totalKb) * 1024;
  final total = totalKb * 1024;
  return MemInfo(
      totalBytes: total, availableBytes: available > total ? total : available);
}

/// Parses `Get-CimInstance Win32_Processor | ConvertTo-Json -Compress`.
({String? model, int? cores}) parseWindowsProcessorJson(String text) {
  final items = _decodeWin32Json(text);
  if (items.isEmpty) return (model: null, cores: null);
  final item = items.first;
  final name = (item['Name'] as String?)?.trim();
  final cores = _asInt(item['NumberOfCores']) ?? _asInt(item['NumberOfLogicalProcessors']);
  return (model: (name == null || name.isEmpty) ? null : name, cores: cores);
}

/// Parses `Get-CimInstance Win32_VideoController | ConvertTo-Json -Compress`.
List<GpuInfo> parseWindowsVideoControllersJson(String text) {
  final items = _decodeWin32Json(text);
  final gpus = <GpuInfo>[];
  for (final item in items) {
    final name = (item['Name'] as String?)?.trim();
    if (name == null || name.isEmpty) continue;
    final ram = _asInt(item['AdapterRAM']) ?? 0;
    gpus.add(GpuInfo(
      name: name,
      backend: _guessWindowsBackend(name),
      // AdapterRAM is a 32-bit field and wraps for cards with >4 GiB; treat bogus
      // values as unknown instead of lying about a 4 GiB card.
      vramBytes: (ram <= 0 || ram > 0xFFFFFFFF ~/ 2) ? 0 : ram,
    ));
  }
  return gpus;
}

GpuBackend _guessWindowsBackend(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('nvidia')) return GpuBackend.cuda;
  if (lower.contains('amd') || lower.contains('radeon') || lower.contains('ati')) {
    return GpuBackend.rocm;
  }
  return GpuBackend.vulkan;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
