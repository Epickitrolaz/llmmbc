import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:llmmbc_core/src/hardware/probe_environment.dart';
import 'package:test/test.dart';

typedef CommandMatcher = ProbeCommandResult? Function(String executable, List<String> arguments);

const _x86Meminfo = '''
MemTotal:       16318476 kB
MemFree:         1234567 kB
MemAvailable:   14234567 kB
Buffers:          123456 kB
Cached:          5678901 kB
''';

const _x86Cpuinfo = '''
processor\t: 0
vendor_id\t: GenuineIntel
model name\t: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz

processor\t: 1
vendor_id\t: GenuineIntel
model name\t: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz
''';

const _piCpuinfo = '''
processor\t: 0
BogoMIPS\t: 108.00
Hardware\t: BCM2835
Revision\t: c03111
Model\t\t: Raspberry Pi 4 Model B Rev 1.4

processor\t: 1
BogoMIPS\t: 108.00
Hardware\t: BCM2835
Revision\t: c03111
Model\t\t: Raspberry Pi 4 Model B Rev 1.4
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

ProbeEnvironment fakeEnvironment({
  String platform = 'linux',
  Map<String, String> files = const {},
  CommandMatcher? commands,
  Map<String, List<String>> directories = const {},
  Map<String, String> envVars = const {},
  int cores = 4,
  String abi = 'linux_x64',
}) {
  return ProbeEnvironment(
    platform: platform,
    readFile: (path) => files[path],
    run: (executable, arguments) async => commands?.call(executable, arguments),
    listDirectory: (path) async => directories[path] ?? const [],
    env: (name) => envVars[name],
    processorCount: cores,
    abi: abi,
  );
}

String meminfo({required int totalKb, required int availableKb}) => '''
MemTotal:       $totalKb kB
MemFree:         100000 kB
MemAvailable:   $availableKb kB
Buffers:          12345 kB
Cached:          200000 kB
''';

void main() {
  test('linux x86 with an NVIDIA GPU', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        files: {
          '/proc/meminfo': _x86Meminfo,
          '/proc/cpuinfo': _x86Cpuinfo,
        },
        commands: (exe, args) {
          if (exe == 'uname' && args.join(' ') == '-m') {
            return const ProbeCommandResult(0, 'x86_64\n', '');
          }
          if (exe == 'nvidia-smi') {
            return const ProbeCommandResult(0, 'NVIDIA GeForce RTX 3060, 12288\n', '');
          }
          if (exe == 'rocm-smi') return const ProbeCommandResult(1, '', 'not found');
          return null;
        },
      ),
    );

    final profile = await probe.scan();
    expect(profile.os, 'linux');
    expect(profile.arch, 'x64');
    expect(profile.cpuModel, 'Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz');
    expect(profile.cpuCores, 2);
    expect(profile.totalRamBytes, 16318476 * 1024);
    expect(profile.availableRamBytes, 14234567 * 1024);
    expect(profile.tags, isEmpty);
    expect(profile.gpus.single.backend, GpuBackend.cuda);
    expect(profile.gpus.single.vramBytes, 12288 * 1024 * 1024);
  });

  test('Raspberry Pi in Docker', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        files: {
          '/proc/meminfo': meminfo(totalKb: 3886108, availableKb: 3000000),
          '/proc/cpuinfo': _piCpuinfo,
          '/proc/device-tree/model': 'Raspberry Pi 4 Model B Rev 1.4\u0000',
          '/.dockerenv': '',
          '/proc/self/cgroup': '0::/docker/abc\n',
        },
        commands: (exe, args) => exe == 'uname' && args.join(' ') == '-m'
            ? const ProbeCommandResult(0, 'aarch64\n', '')
            : null,
      ),
    );

    final profile = await probe.scan();
    expect(profile.os, 'linux');
    expect(profile.arch, 'arm64');
    expect(profile.cpuModel, 'Raspberry Pi 4 Model B Rev 1.4');
    expect(profile.tags, containsAll(['raspberry-pi', 'docker']));
    expect(profile.gpus, isEmpty);
  });

  test('cgroup v2 memory limit lowers total and clamps available RAM', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        files: {
          '/proc/meminfo': meminfo(totalKb: 16777216, availableKb: 15728640),
          '/proc/cpuinfo': _x86Cpuinfo,
          '/.dockerenv': '',
          '/sys/fs/cgroup/memory.max': '4294967296\n',
          '/sys/fs/cgroup/memory.current': '1073741824\n',
        },
        commands: (exe, args) => exe == 'uname' && args.join(' ') == '-m'
            ? const ProbeCommandResult(0, 'x86_64\n', '')
            : null,
      ),
    );

    final profile = await probe.scan();
    expect(profile.totalRamBytes, 4 << 30);
    expect(profile.availableRamBytes, 3 << 30);
    expect(profile.tags, contains('docker'));
  });

  test('cgroup v1 nested container memory limit', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        files: {
          '/proc/meminfo': meminfo(totalKb: 8388608, availableKb: 8000000),
          '/proc/self/cgroup': '5:memory:/docker/abc\n0::/\n',
          '/sys/fs/cgroup/memory/docker/abc/memory.limit_in_bytes': '2147483648\n',
          '/sys/fs/cgroup/memory/docker/abc/memory.usage_in_bytes': '536870912\n',
        },
        commands: (exe, args) => exe == 'uname' && args.join(' ') == '-m'
            ? const ProbeCommandResult(0, 'x86_64\n', '')
            : null,
      ),
    );

    final profile = await probe.scan();
    expect(profile.totalRamBytes, 2 << 30);
    expect(profile.availableRamBytes, (2 << 30) - (512 << 20));
    expect(profile.tags, contains('docker'));
  });

  test('Android emulator with a GPU renderer hook', () async {
    final probe = LocalHardwareProbe(
      hooks: PlatformHooks(gpuRenderer: () async => 'Adreno (TM) 640'),
      environment: fakeEnvironment(
        platform: 'android',
        files: {
          '/proc/meminfo': meminfo(totalKb: 4194304, availableKb: 2097152),
          '/proc/cpuinfo':
              'processor\t: 0\nmodel name\t: Android virtual processor\n',
        },
        commands: (exe, args) {
          if (exe == 'uname' && args.join(' ') == '-m') {
            return const ProbeCommandResult(0, 'aarch64\n', '');
          }
          if (exe == 'getprop' && args.single == 'ro.kernel.qemu') {
            return const ProbeCommandResult(0, '1\n', '');
          }
          return null;
        },
      ),
    );

    final profile = await probe.scan();
    expect(profile.os, 'android');
    expect(profile.arch, 'arm64');
    expect(profile.tags, contains('emulator'));
    expect(profile.gpus.single.name, 'Adreno (TM) 640');
    expect(profile.gpus.single.backend, GpuBackend.opencl);
    expect(profile.gpus.single.vramBytes, 0);
  });

  test('Android emulator detected via /proc/cmdline', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        platform: 'android',
        files: {
          '/proc/meminfo': meminfo(totalKb: 2097152, availableKb: 1048576),
          '/proc/cmdline': 'console=ttyMSM0 androidboot.hardware=ranchu',
        },
        commands: (exe, args) => exe == 'uname' && args.join(' ') == '-m'
            ? const ProbeCommandResult(0, 'aarch64\n', '')
            : null,
      ),
    );

    final profile = await probe.scan();
    expect(profile.tags, contains('emulator'));
    expect(profile.tags, isNot(contains('docker')));
  });

  test('macOS Apple Silicon reports Metal with unified memory', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        platform: 'macos',
        commands: (exe, args) {
          if (exe == 'uname' && args.join(' ') == '-m') {
            return const ProbeCommandResult(0, 'arm64\n', '');
          }
          if (exe == 'sysctl') {
            switch (args.join(' ')) {
              case '-n hw.memsize':
                return const ProbeCommandResult(0, '17179869184\n', '');
              case '-n machdep.cpu.brand_string':
                return const ProbeCommandResult(0, 'Apple M1 Pro\n', '');
              case '-n hw.ncpu':
                return const ProbeCommandResult(0, '8\n', '');
              case '-n hw.model':
                return const ProbeCommandResult(0, 'MacBookPro18,3\n', '');
            }
          }
          if (exe == 'vm_stat') return const ProbeCommandResult(0, _vmStat, '');
          if (exe == 'system_profiler') {
            return const ProbeCommandResult(0, 'Chipset Model: Apple M1 Pro\n', '');
          }
          return null;
        },
      ),
    );

    final profile = await probe.scan();
    expect(profile.os, 'macos');
    expect(profile.arch, 'arm64');
    expect(profile.cpuModel, 'Apple M1 Pro');
    expect(profile.cpuCores, 8);
    expect(profile.totalRamBytes, 16 << 30);
    expect(profile.availableRamBytes, 249001 * 16384);
    expect(profile.gpus.single.backend, GpuBackend.metal);
    expect(profile.gpus.single.name, 'Apple M1 Pro');
    expect(profile.gpus.single.vramBytes, 0);
  });

  test('Windows via PowerShell CIM', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        platform: 'windows',
        envVars: {'PROCESSOR_ARCHITECTURE': 'AMD64'},
        commands: (exe, args) {
          if (exe != 'powershell') return null;
          final command = args.last;
          if (command.contains('Win32_OperatingSystem')) {
            return const ProbeCommandResult(
                0, '{"TotalVisibleMemorySize":16777216,"FreePhysicalMemory":8388608}', '');
          }
          if (command.contains('Win32_Processor')) {
            return const ProbeCommandResult(
                0,
                '{"Name":"AMD Ryzen 9 5900X 12-Core Processor","NumberOfCores":12,'
                '"NumberOfLogicalProcessors":24}',
                '');
          }
          if (command.contains('Win32_VideoController')) {
            return const ProbeCommandResult(
                0,
                '[{"Name":"NVIDIA GeForce RTX 3080","AdapterRAM":1073741824},'
                '{"Name":"Microsoft Basic Display Adapter","AdapterRAM":null}]',
                '');
          }
          return null;
        },
      ),
    );

    final profile = await probe.scan();
    expect(profile.os, 'windows');
    expect(profile.arch, 'x64');
    expect(profile.cpuModel, 'AMD Ryzen 9 5900X 12-Core Processor');
    expect(profile.cpuCores, 12);
    expect(profile.totalRamBytes, 16 << 30);
    expect(profile.availableRamBytes, 8 << 30);
    expect(profile.gpus, hasLength(2));
    expect(profile.gpus.first.backend, GpuBackend.cuda);
  });

  test('Windows falls back to wmic when PowerShell is unavailable', () async {
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        platform: 'windows',
        envVars: {'PROCESSOR_ARCHITECTURE': 'ARM64'},
        commands: (exe, args) {
          if (exe != 'wmic') return null;
          if (args.first == 'OS') {
            return const ProbeCommandResult(
                0, 'FreePhysicalMemory=4194304\r\nTotalVisibleMemorySize=8388608\r\n', '');
          }
          if (args.first == 'cpu') {
            return const ProbeCommandResult(0, 'Name=Snapdragon X Elite\r\n', '');
          }
          return null;
        },
      ),
    );

    final profile = await probe.scan();
    expect(profile.arch, 'arm64');
    expect(profile.cpuModel, 'Snapdragon X Elite');
    expect(profile.totalRamBytes, 8 << 30);
    expect(profile.availableRamBytes, 4 << 30);
    expect(profile.gpus, isEmpty);
  });

  test('never throws when every probe source fails', () async {
    final environment = ProbeEnvironment(
      platform: 'linux',
      readFile: (_) => throw StateError('read failed'),
      run: (_, __) async => throw StateError('exec failed'),
      listDirectory: (_) async => throw StateError('list failed'),
      env: (_) => throw StateError('env failed'),
      processorCount: 1,
      abi: 'linux_x64',
    );

    final profile = await LocalHardwareProbe(environment: environment).scan();
    expect(profile.os, 'linux');
    expect(profile.arch, 'x64');
    expect(profile.cpuCores, 1);
    expect(profile.totalRamBytes, 1 << 30);
    expect(profile.availableRamBytes, 512 << 20);
    expect(profile.gpus, isEmpty);
    expect(profile.tags, isEmpty);
    // 512 MiB available minus the 256 MiB minimum reserve (#47).
    expect(profile.usableMemoryBytes, 256 << 20);
  });

  test('garbage /proc files degrade to conservative values', () async {
    final profile = await LocalHardwareProbe(
      environment: fakeEnvironment(
        files: {'/proc/meminfo': 'not a meminfo', '/proc/cpuinfo': 'nonsense'},
        commands: (exe, args) => exe == 'uname'
            ? const ProbeCommandResult(0, 'unknown-machine\n', '')
            : null,
      ),
    ).scan();

    expect(profile.totalRamBytes, 1 << 30);
    expect(profile.cpuCores, 4); // environment fallback
    expect(profile.gpus, isEmpty);
  });

  test('refresh only re-reads available RAM', () async {
    final files = <String, String>{
      '/proc/meminfo': meminfo(totalKb: 16318476, availableKb: 14234567),
      '/proc/cpuinfo': _x86Cpuinfo,
    };
    final probe = LocalHardwareProbe(
      environment: fakeEnvironment(
        files: files,
        commands: (exe, args) => exe == 'uname' && args.join(' ') == '-m'
            ? const ProbeCommandResult(0, 'x86_64\n', '')
            : null,
      ),
    );

    final first = await probe.scan();
    files['/proc/meminfo'] = meminfo(totalKb: 16318476, availableKb: 4000000);
    final refreshed = await probe.refresh(first);

    expect(refreshed.totalRamBytes, first.totalRamBytes);
    expect(refreshed.availableRamBytes, 4000000 * 1024);
    expect(refreshed.cpuModel, first.cpuModel);
    expect(refreshed.cpuCores, first.cpuCores);
    expect(refreshed.gpus, first.gpus);
  });

  test('refresh returns the previous profile when reading fails', () async {
    const previous = HardwareProfile(
      os: 'linux',
      arch: 'x64',
      cpuModel: 'cpu',
      cpuCores: 8,
      totalRamBytes: 16 << 30,
      availableRamBytes: 12 << 30,
      tags: ['docker'],
    );
    final profile = await LocalHardwareProbe(
      environment: ProbeEnvironment(
        platform: 'linux',
        readFile: (_) => null,
        run: (_, __) async => null,
        listDirectory: (_) async => const [],
        env: (_) => null,
        processorCount: 8,
        abi: 'linux_x64',
      ),
    ).refresh(previous);

    expect(profile.totalRamBytes, previous.totalRamBytes);
    expect(profile.availableRamBytes, previous.availableRamBytes);
    expect(profile.tags, previous.tags);
  });
}
