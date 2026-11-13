import 'package:llmmbc_core/src/hardware/probe_parsers.dart';
import 'package:llmmbc_core/src/models.dart';
import 'package:test/test.dart';

const _x86Meminfo = '''
MemTotal:       16318476 kB
MemFree:         1234567 kB
MemAvailable:   14234567 kB
Buffers:          123456 kB
Cached:          5678901 kB
SwapTotal:             0 kB
SwapFree:              0 kB
''';

const _piCpuinfo = '''
processor\t: 0
BogoMIPS\t: 108.00
Features\t: fp asimd evtstrm crc32 cpuid
CPU implementer\t: 0x41
CPU architecture: 8
Hardware\t: BCM2835
Revision\t: c03111
Model\t\t: Raspberry Pi 4 Model B Rev 1.4

processor\t: 1
BogoMIPS\t: 108.00
Features\t: fp asimd evtstrm crc32 cpuid
CPU implementer\t: 0x41
CPU architecture: 8
Hardware\t: BCM2835
Revision\t: c03111
Model\t\t: Raspberry Pi 4 Model B Rev 1.4
''';

const _x86Cpuinfo = '''
processor\t: 0
vendor_id\t: GenuineIntel
model name\t: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz
cpu MHz\t\t: 2599.998

processor\t: 1
vendor_id\t: GenuineIntel
model name\t: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz
cpu MHz\t\t: 2599.998
''';

const _vmStat = '''
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               43001.
Pages active:                            100000.
Pages inactive:                          200000.
Pages speculative:                         5000.
Pages wired down:                         60000.
Pages purgeable:                           1000.
''';

void main() {
  group('meminfo', () {
    test('parses total and MemAvailable', () {
      final mem = parseMeminfo(_x86Meminfo)!;
      expect(mem.totalBytes, 16318476 * 1024);
      expect(mem.availableBytes, 14234567 * 1024);
    });

    test('approximates MemAvailable on old kernels', () {
      const text = '''
MemTotal:       1000 kB
MemFree:         100 kB
Buffers:          50 kB
Cached:          200 kB
SReclaimable:     25 kB
Shmem:            25 kB
''';
      expect(parseMeminfo(text)!.availableBytes, 350 * 1024);
    });

    test('returns null without MemTotal', () {
      expect(parseMeminfo('MemFree: 10 kB'), isNull);
    });
  });

  group('cgroups', () {
    test('parses finite limits and rejects unlimited markers', () {
      expect(parseCgroupMemoryLimit('4294967296'), 4294967296);
      expect(parseCgroupMemoryLimit('max'), isNull);
      expect(parseCgroupMemoryLimit('9223372036854771712'), isNull);
      expect(parseCgroupMemoryLimit(''), isNull);
    });

    test('lowers total and clamps availability', () {
      final mem = parseMeminfo(_x86Meminfo)!;
      final limited = applyCgroupLimit(mem, 4 << 30, 1 << 30);
      expect(limited.totalBytes, 4 << 30);
      expect(limited.availableBytes, 3 << 30);
    });

    test('ignores a limit above physical memory', () {
      final mem = parseMeminfo(_x86Meminfo)!;
      expect(applyCgroupLimit(mem, 64 << 30, 0).totalBytes, mem.totalBytes);
    });

    test('detects container runtimes', () {
      expect(detectContainer('', dockerenvPresent: true), isTrue);
      expect(detectContainer('5:memory:/docker/abc123\n0::/'), isTrue);
      expect(detectContainer('0::/kubepods/besteffort/pod1/abc'), isTrue);
      expect(detectContainer('0::/user.slice/user-1000.slice/session-2.scope'), isFalse);
    });
  });

  group('cpu', () {
    test('x86 model name and core count', () {
      expect(parseCpuModel(_x86Cpuinfo), 'Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz');
      expect(parseCpuCoreCount(_x86Cpuinfo), 2);
    });

    test('Raspberry Pi Model line wins over Hardware', () {
      expect(parseCpuModel(_piCpuinfo), 'Raspberry Pi 4 Model B Rev 1.4');
      expect(parseCpuCoreCount(_piCpuinfo), 2);
    });

    test('device-tree model strips NUL padding', () {
      expect(normalizeDeviceTreeModel('Raspberry Pi 5 Model B Rev 1.0\u0000\u0000'), 'Raspberry Pi 5 Model B Rev 1.0');
      expect(isRaspberryPiModel('raspberry pi 4 model b'), isTrue);
      expect(isRaspberryPiModel('Generic ARM board'), isFalse);
    });
  });

  group('arch', () {
    test('normalises common uname/ABI values', () {
      expect(normalizeArch('x86_64'), 'x64');
      expect(normalizeArch('AMD64\n'), 'x64');
      expect(normalizeArch('aarch64'), 'arm64');
      expect(normalizeArch('armv7l'), 'arm');
      expect(normalizeArch('i686'), 'ia32');
      expect(normalizeArch('linux_x64'), 'x64');
      expect(normalizeArch('androidArm64'), 'arm64');
      expect(normalizeArch('mips'), '');
    });
  });

  group('gpus', () {
    test('parses nvidia-smi csv', () {
      final gpus = parseNvidiaSmi('NVIDIA GeForce RTX 3060, 12288\nNVIDIA RTX A4000, 16376\n');
      expect(gpus, hasLength(2));
      expect(gpus.first.name, 'NVIDIA GeForce RTX 3060');
      expect(gpus.first.backend, GpuBackend.cuda);
      expect(gpus.first.vramBytes, 12288 * 1024 * 1024);
    });

    test('parses rocm-smi csv', () {
      final gpus = parseRocmSmi(
          'device,VRAM Total Memory (B),VRAM Total Used Memory (B)\ncard0,8573157376,123456789\n');
      expect(gpus, hasLength(1));
      expect(gpus.single.name, 'AMD GPU (card0)');
      expect(gpus.single.backend, GpuBackend.rocm);
      expect(gpus.single.vramBytes, 8573157376);
    });

    test('parses sysfs VRAM', () {
      expect(parseSysfsVramTotal('8589934592\n'), 8589934592);
      expect(parseSysfsVramTotal('garbage'), isNull);
      final gpu = rocmGpuFromSysfs('card1', 8 << 30, productName: 'Radeon RX 6800');
      expect(gpu.name, 'Radeon RX 6800');
      expect(gpu.backend, GpuBackend.rocm);
    });

    test('guesses Android backends and keeps unified memory at 0', () {
      expect(guessAndroidGpuBackend('Adreno (TM) 640'), GpuBackend.opencl);
      expect(guessAndroidGpuBackend('Vulkan 1.1, Mali-G78'), GpuBackend.vulkan);
    });

    test('parses system_profiler chipset name', () {
      const text = '''
Graphics/Displays:
      Apple M1 Pro:
        Chipset Model: Apple M1 Pro
        Type: GPU
''';
      expect(parseSystemProfilerGpu(text), 'Apple M1 Pro');
    });
  });

  group('macos', () {
    test('parses sysctl values', () {
      expect(parseSysctlInt('17179869184\n'), 17179869184);
      expect(parseSysctlInt('hw.memsize: 17179869184\n'), 17179869184);
      expect(parseSysctlString('Apple M1 Pro\n'), 'Apple M1 Pro');
      expect(parseSysctlString('hw.model: MacBookPro18,3\n'), 'MacBookPro18,3');
    });

    test('computes available memory from vm_stat', () {
      // (43001 + 200000 + 5000 + 1000) pages * 16384 bytes
      expect(parseVmStat(_vmStat), 249001 * 16384);
    });

    test('falls back to 4096-byte pages', () {
      const text = 'Pages free: 100.\nPages inactive: 100.\n';
      expect(parseVmStat(text), 200 * 4096);
    });
  });

  group('windows', () {
    test('parses wmic list memory (KiB)', () {
      final mem = parseWmicMemory(
          'FreePhysicalMemory=8388608\r\nTotalVisibleMemorySize=16777216\r\n');
      expect(mem!.totalBytes, 16 << 30);
      expect(mem.availableBytes, 8 << 30);
    });

    test('parses CIM JSON memory', () {
      final mem = parseWindowsOperatingSystemJson(
          '{"TotalVisibleMemorySize":16777216,"FreePhysicalMemory":4194304}');
      expect(mem!.totalBytes, 16 << 30);
      expect(mem.availableBytes, 4 << 30);
    });

    test('parses CIM JSON processor', () {
      final cpu = parseWindowsProcessorJson(
          '{"Name":"AMD Ryzen 9 5900X 12-Core Processor","NumberOfCores":12,"NumberOfLogicalProcessors":24}');
      expect(cpu.model, 'AMD Ryzen 9 5900X 12-Core Processor');
      expect(cpu.cores, 12);
    });

    test('parses CIM JSON video controllers', () {
      const json = '[{"Name":"NVIDIA GeForce RTX 3080","AdapterRAM":1073741824},'
          '{"Name":"Microsoft Basic Display Adapter","AdapterRAM":null}]';
      final gpus = parseWindowsVideoControllersJson(json);
      expect(gpus, hasLength(2));
      expect(gpus.first.backend, GpuBackend.cuda);
      expect(gpus.first.vramBytes, 1073741824);
      expect(gpus.last.backend, GpuBackend.vulkan);
      expect(gpus.last.vramBytes, 0);
    });
  });
}
