// Local hardware probe. Owned by core-data (docs/ARCHITECTURE.md §2.1).
import 'dart:async';

import '../interfaces.dart';
import '../models.dart';
import 'probe_environment.dart';
import 'probe_parsers.dart';

/// Scans the local device into a [HardwareProfile].
///
/// The probe never throws: every failed source degrades to a conservative value
/// (1 core, 1 GiB total / 512 MiB available, no GPUs). Parsing lives in pure functions in
/// `probe_parsers.dart` so it can be unit-tested with captured fixture text; [environment]
/// allows tests to replace file/command access.
class LocalHardwareProbe implements HardwareProbe {
  final PlatformHooks hooks;
  final ProbeEnvironment environment;

  LocalHardwareProbe({this.hooks = const PlatformHooks(), ProbeEnvironment? environment})
      : environment = environment ?? ProbeEnvironment.real();

  /// Conservative values used when no probe succeeds.
  static const int _fallbackTotalRam = 1 << 30;
  static const int _fallbackAvailableRam = 512 << 20;

  @override
  Future<HardwareProfile> scan() async {
    final platform = _safePlatform();
    try {
      final arch = await _detectArch(platform);
      final profile = switch (platform) {
        'macos' || 'ios' => await _scanApple(platform, arch),
        'windows' => await _scanWindows(arch),
        'android' => await _scanLinux(platform, arch),
        'linux' => await _scanLinux(platform, arch),
        _ => await _scanLinux(platform, arch),
      };
      return _sanitize(profile, platform, arch);
    } catch (_) {
      return _fallback(platform);
    }
  }

  @override
  Future<HardwareProfile> refresh(HardwareProfile previous) async {
    try {
      final available = await _readAvailableRam();
      if (available == null) return previous;
      var clamped = available;
      if (clamped < 0) clamped = 0;
      if (clamped > previous.totalRamBytes) clamped = previous.totalRamBytes;
      return HardwareProfile(
        os: previous.os,
        arch: previous.arch,
        cpuModel: previous.cpuModel,
        cpuCores: previous.cpuCores,
        totalRamBytes: previous.totalRamBytes,
        availableRamBytes: clamped,
        gpus: previous.gpus,
        tags: previous.tags,
      );
    } catch (_) {
      return previous;
    }
  }

  // -------------------------------------------------------------------------
  // Linux / Android
  // -------------------------------------------------------------------------

  Future<HardwareProfile> _scanLinux(String platform, String arch) async {
    final mem = _procMemory();
    final cpuinfo = environment.readFile('/proc/cpuinfo');
    final cpuModel = (cpuinfo == null ? null : parseCpuModel(cpuinfo)) ?? '';
    final cores = (cpuinfo == null ? null : parseCpuCoreCount(cpuinfo)) ??
        environment.processorCount;

    final tags = <String>{};
    final deviceTree = normalizeDeviceTreeModel(
        environment.readFile('/proc/device-tree/model'));
    final isPi = isRaspberryPiModel(deviceTree) ||
        cpuModel.toLowerCase().contains('raspberry pi');
    if (isPi) tags.add('raspberry-pi');

    final cgroupText = [
      environment.readFile('/proc/self/cgroup'),
      environment.readFile('/proc/1/cgroup'),
    ].whereType<String>().join('\n');
    if (detectContainer(cgroupText,
        dockerenvPresent: environment.readFile('/.dockerenv') != null)) {
      tags.add('docker');
    }

    final gpus = <GpuInfo>[];
    if (platform == 'android') {
      if (await _isAndroidEmulator()) tags.add('emulator');
      gpus.addAll(await _androidGpus());
    } else {
      gpus.addAll(await _linuxGpus());
    }

    return HardwareProfile(
      os: platform,
      arch: arch,
      cpuModel: cpuModel,
      cpuCores: cores,
      totalRamBytes: mem.totalBytes,
      availableRamBytes: mem.availableBytes,
      gpus: gpus,
      tags: tags.toList(),
    );
  }

  /// `/proc/meminfo`, lowered to the cgroup limit when the process is constrained.
  MemInfo _procMemory() {
    final text = environment.readFile('/proc/meminfo');
    final parsed = text == null ? null : parseMeminfo(text);
    final limits = _readCgroupLimits();
    if (parsed == null) {
      final total = limits.limit ?? _fallbackTotalRam;
      var available = _fallbackAvailableRam;
      if (limits.usage != null) {
        final remaining = total - limits.usage!;
        if (remaining < available) available = remaining;
      }
      if (available < 0) available = 0;
      if (available > total) available = total;
      return MemInfo(totalBytes: total, availableBytes: available);
    }
    return applyCgroupLimit(parsed, limits.limit, limits.usage);
  }

  ({int? limit, int? usage}) _readCgroupLimits() {
    int? firstValid(List<String> paths) {
      for (final path in paths) {
        final text = environment.readFile(path);
        if (text == null) continue;
        final value = parseCgroupMemoryLimit(text);
        if (value != null) return value;
      }
      return null;
    }

    // Discover the process' own cgroup path (v1 per-controller and v2 unified layouts).
    final paths = <String>[];
    final usagePaths = <String>[];
    final cgroup = environment.readFile('/proc/self/cgroup') ?? '';
    for (final rawLine in cgroup.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final parts = line.split(':');
      if (parts.length < 3) continue;
      final controllers = parts[1];
      final path = parts.sublist(2).join(':').trim();
      if (controllers.isEmpty) {
        // cgroup v2: "0::/user.slice/..."
        paths.add('/sys/fs/cgroup$path/memory.max');
        usagePaths.add('/sys/fs/cgroup$path/memory.current');
      } else if (controllers.split(',').contains('memory')) {
        // cgroup v1: "5:memory:/docker/<id>"
        paths.add('/sys/fs/cgroup/memory$path/memory.limit_in_bytes');
        usagePaths.add('/sys/fs/cgroup/memory$path/memory.usage_in_bytes');
      }
    }
    // Common container/root layouts as fallbacks.
    paths.addAll(const [
      '/sys/fs/cgroup/memory.max',
      '/sys/fs/cgroup/memory/memory.limit_in_bytes',
    ]);
    usagePaths.addAll(const [
      '/sys/fs/cgroup/memory.current',
      '/sys/fs/cgroup/memory/memory.usage_in_bytes',
    ]);
    return (limit: firstValid(paths), usage: firstValid(usagePaths));
  }

  Future<bool> _isAndroidEmulator() async {
    final qemu = await environment.run('getprop', ['ro.kernel.qemu']);
    if ((qemu?.stdout ?? '').trim() == '1') return true;
    final hardware = await environment.run('getprop', ['ro.hardware']);
    final board = await environment.run('getprop', ['ro.product.board']);
    final marker = '${hardware?.stdout ?? ''} ${board?.stdout ?? ''}'.toLowerCase();
    if (marker.contains('goldfish') || marker.contains('ranchu') || marker.contains('qemu')) {
      return true;
    }
    // Emulators without getprop still advertise the virtual board on the kernel cmdline.
    final cmdline = (environment.readFile('/proc/cmdline') ?? '').toLowerCase();
    return cmdline.contains('goldfish') ||
        cmdline.contains('ranchu') ||
        cmdline.contains('qemu');
  }

  Future<List<GpuInfo>> _androidGpus() async {
    final renderer = await _gpuRenderer();
    if (renderer == null || renderer.trim().isEmpty) return const [];
    return [
      GpuInfo(
        name: renderer.trim(),
        backend: guessAndroidGpuBackend(renderer),
        // Unified memory: Android GPUs have no dedicated VRAM.
        vramBytes: 0,
      )
    ];
  }

  Future<String?> _gpuRenderer() async {
    final hook = hooks.gpuRenderer;
    if (hook == null) return null;
    try {
      return await hook().timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  Future<List<GpuInfo>> _linuxGpus() async {
    final gpus = <GpuInfo>[];
    final nvidia = await environment.run(
        'nvidia-smi', ['--query-gpu=name,memory.total', '--format=csv,noheader,nounits']);
    if (nvidia != null && nvidia.ok) gpus.addAll(parseNvidiaSmi(nvidia.stdout));

    final rocm = await environment.run('rocm-smi', ['--showmeminfo', 'vram', '--csv']);
    if (rocm != null && rocm.ok) {
      gpus.addAll(parseRocmSmi(rocm.stdout));
    }
    if (!gpus.any((g) => g.backend == GpuBackend.rocm)) {
      gpus.addAll(await _sysfsAmdGpus());
    }
    return gpus;
  }

  Future<List<GpuInfo>> _sysfsAmdGpus() async {
    final entries = await environment.listDirectory('/sys/class/drm');
    final cards = <String>[];
    for (final entry in entries) {
      final segments = entry.split('/').where((p) => p.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      final name = segments.last;
      if (!RegExp(r'^card\d+$').hasMatch(name)) continue;
      cards.add(entry);
    }
    cards.sort();
    final gpus = <GpuInfo>[];
    for (final cardPath in cards) {
      final raw = environment.readFile('$cardPath/device/mem_info_vram_total');
      if (raw == null) continue;
      final vram = parseSysfsVramTotal(raw);
      if (vram == null) continue;
      final product = environment.readFile('$cardPath/device/product_name');
      final card = cardPath.split('/').where((p) => p.isNotEmpty).last;
      gpus.add(rocmGpuFromSysfs(card, vram, productName: product));
    }
    return gpus;
  }

  // -------------------------------------------------------------------------
  // macOS / iOS
  // -------------------------------------------------------------------------

  Future<HardwareProfile> _scanApple(String platform, String arch) async {
    final total = parseSysctlInt(await _runText('sysctl', ['-n', 'hw.memsize']) ?? '') ??
        _fallbackTotalRam;

    int? available;
    final vmStat = await _runText('vm_stat', const []);
    if (vmStat != null) available = parseVmStat(vmStat);
    available ??= total ~/ 2;

    final brand = parseSysctlString(
        await _runText('sysctl', ['-n', 'machdep.cpu.brand_string']) ?? '');
    final model = parseSysctlString(await _runText('sysctl', ['-n', 'hw.model']) ?? '');
    final cpuModel = brand ?? model ?? '';

    final ncpu = parseSysctlInt(await _runText('sysctl', ['-n', 'hw.ncpu']) ?? '');
    final cores = ncpu ?? environment.processorCount;

    final gpus = <GpuInfo>[];
    if (arch == 'arm64') {
      // Apple Silicon: unified memory, so VRAM is unknown (0) and llama.cpp uses Metal.
      final profiler = await _runText('system_profiler', ['SPDisplaysDataType']);
      final name = (profiler == null ? null : parseSystemProfilerGpu(profiler)) ??
          (brand != null && brand.toLowerCase().contains('apple') ? brand : 'Apple Silicon GPU');
      gpus.add(GpuInfo(name: name, backend: GpuBackend.metal, vramBytes: 0));
    } else {
      final profiler = await _runText('system_profiler', ['SPDisplaysDataType']);
      final name = profiler == null ? null : parseSystemProfilerGpu(profiler);
      if (name != null) {
        gpus.add(GpuInfo(name: name, backend: GpuBackend.metal, vramBytes: 0));
      }
    }

    return HardwareProfile(
      os: platform,
      arch: arch,
      cpuModel: cpuModel,
      cpuCores: cores,
      totalRamBytes: total,
      availableRamBytes: available,
      gpus: gpus,
    );
  }

  // -------------------------------------------------------------------------
  // Windows
  // -------------------------------------------------------------------------

  Future<HardwareProfile> _scanWindows(String arch) async {
    const psPrefix = ['-NoProfile', '-NonInteractive', '-Command'];

    // Memory: PowerShell CIM first, wmic as fallback.
    MemInfo? mem;
    final osJson = await _runText(
        'powershell',
        [
          ...psPrefix,
          'Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory | ConvertTo-Json -Compress',
        ]);
    if (osJson != null) mem = parseWindowsOperatingSystemJson(osJson);
    if (mem == null) {
      final wmic =
          await _runText('wmic', ['OS', 'get', 'TotalVisibleMemorySize,FreePhysicalMemory', '/format:list']);
      if (wmic != null) mem = parseWmicMemory(wmic);
    }
    mem ??= const MemInfo(totalBytes: _fallbackTotalRam, availableBytes: _fallbackAvailableRam);

    // CPU.
    String? cpuModel;
    int? cores;
    final cpuJson = await _runText(
        'powershell',
        [
          ...psPrefix,
          'Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors | ConvertTo-Json -Compress',
        ]);
    if (cpuJson != null) {
      final parsed = parseWindowsProcessorJson(cpuJson);
      cpuModel = parsed.model;
      cores = parsed.cores;
    }
    if (cpuModel == null) {
      final wmic = await _runText('wmic', ['cpu', 'get', 'Name', '/format:list']);
      cpuModel = wmic == null ? null : _wmicString(wmic, 'Name');
    }
    cores ??= environment.processorCount;

    // GPUs.
    var gpus = <GpuInfo>[];
    final gpuJson = await _runText(
        'powershell',
        [
          ...psPrefix,
          'Get-CimInstance Win32_VideoController | Select-Object Name,AdapterRAM | ConvertTo-Json -Compress',
        ]);
    if (gpuJson != null) gpus = parseWindowsVideoControllersJson(gpuJson);

    return HardwareProfile(
      os: 'windows',
      arch: arch,
      cpuModel: cpuModel ?? '',
      cpuCores: cores,
      totalRamBytes: mem.totalBytes,
      availableRamBytes: mem.availableBytes,
      gpus: gpus,
    );
  }

  // -------------------------------------------------------------------------
  // Shared helpers
  // -------------------------------------------------------------------------

  String _safePlatform() {
    try {
      final platform = environment.platform.trim();
      return platform.isEmpty ? 'linux' : platform;
    } catch (_) {
      return 'linux';
    }
  }

  Future<String> _detectArch(String platform) async {
    String? candidate;
    if (platform == 'windows') {
      candidate = environment.env('PROCESSOR_ARCHITECTURE');
    } else {
      final uname = await environment.run('uname', ['-m']);
      if (uname != null && uname.ok) candidate = uname.stdout;
    }
    final normalized = normalizeArch(candidate ?? '');
    if (normalized.isNotEmpty) return normalized;
    final fromAbi = normalizeArch(environment.abi);
    return fromAbi.isEmpty ? 'x64' : fromAbi;
  }

  /// Only re-reads available RAM (used by [refresh]).
  Future<int?> _readAvailableRam() async {
    switch (_safePlatform()) {
      case 'macos' || 'ios':
        final vmStat = await _runText('vm_stat', const []);
        if (vmStat != null) return parseVmStat(vmStat);
        return null;
      case 'windows':
        final json = await _runText(
            'powershell',
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              'Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory | ConvertTo-Json -Compress',
            ]);
        if (json != null) return parseWindowsOperatingSystemJson(json)?.availableBytes;
        final wmic =
            await _runText('wmic', ['OS', 'get', 'TotalVisibleMemorySize,FreePhysicalMemory', '/format:list']);
        if (wmic != null) return parseWmicMemory(wmic)?.availableBytes;
        return null;
      default:
        final text = environment.readFile('/proc/meminfo');
        final parsed = text == null ? null : parseMeminfo(text);
        if (parsed == null) return null;
        final limits = _readCgroupLimits();
        var available = parsed.availableBytes;
        if (limits.limit != null && limits.usage != null) {
          final remaining = limits.limit! - limits.usage!;
          if (remaining < available) available = remaining;
        }
        return available;
    }
  }

  Future<String?> _runText(String executable, List<String> arguments) async {
    final result = await environment.run(executable, arguments);
    if (result == null || !result.ok) return null;
    return result.stdout;
  }

  String? _wmicString(String text, String key) {
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.toLowerCase().startsWith('${key.toLowerCase()}=')) {
        final value = line.substring(key.length + 1).trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  HardwareProfile _sanitize(HardwareProfile profile, String platform, String arch) {
    final total = profile.totalRamBytes <= 0 ? _fallbackTotalRam : profile.totalRamBytes;
    var available = profile.availableRamBytes;
    if (available < 0) available = 0;
    if (available > total) available = total;
    final cores = profile.cpuCores <= 0 ? 1 : profile.cpuCores;
    return HardwareProfile(
      os: profile.os.isEmpty ? platform : profile.os,
      arch: profile.arch.isEmpty ? arch : profile.arch,
      cpuModel: profile.cpuModel,
      cpuCores: cores,
      totalRamBytes: total,
      availableRamBytes: available,
      gpus: profile.gpus,
      tags: profile.tags,
    );
  }

  HardwareProfile _fallback(String platform) {
    var arch = 'x64';
    try {
      final fromAbi = normalizeArch(environment.abi);
      if (fromAbi.isNotEmpty) arch = fromAbi;
    } catch (_) {
      // Keep x64.
    }
    return HardwareProfile(
      os: platform,
      arch: arch,
      cpuModel: '',
      cpuCores: 1,
      totalRamBytes: _fallbackTotalRam,
      availableRamBytes: _fallbackAvailableRam,
    );
  }
}
