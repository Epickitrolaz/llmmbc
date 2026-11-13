import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

void main() {
  test('ModelRef parse/format', () {
    expect(ModelRef.parse('qwen3:30b-a3b').toString(), 'qwen3:30b-a3b');
    expect(ModelRef.parse('library/qwen3').toString(), 'qwen3:latest');
    expect(ModelRef.parse('foo/bar:1b').namespace, 'foo');
    expect(() => ModelRef.parse('hf.co/x/y'), throwsFormatException);
    expect(() => ModelRef.parse('hf.co/x'), throwsFormatException);
    expect(ModelRef.parse('llama3.2:1b').toString(), 'llama3.2:1b');
    expect(ModelRef.parse('granite3.1-moe:1b').name, 'granite3.1-moe');
  });

  test('usableMemoryBytes reserves a slice of available RAM (#47)', () {
    const gib = 1 << 30, mib = 1 << 20;
    HardwareProfile hw(int total, int avail) => HardwareProfile(
        os: 'linux',
        arch: 'x64',
        cpuModel: '',
        cpuCores: 4,
        totalRamBytes: total,
        availableRamBytes: avail);
    // 31 GiB host with ~5.7 GiB available: reserve capped at 10% of available.
    expect(hw(31 * gib, 5734 * mib).usableMemoryBytes,
        5734 * mib - (5734 * mib) ~/ 10);
    // Phone: 8 GiB total, 2 GiB available -> 256 MiB floor.
    expect(hw(8 * gib, 2 * gib).usableMemoryBytes, 2 * gib - 256 * mib);
    // Big host: reserve capped at 1 GiB.
    expect(hw(128 * gib, 64 * gib).usableMemoryBytes, 63 * gib);
    // Never negative; VRAM added on top.
    expect(hw(gib, 100 * mib).usableMemoryBytes, 0);
    const withGpu = HardwareProfile(
        os: 'linux',
        arch: 'x64',
        cpuModel: '',
        cpuCores: 4,
        totalRamBytes: 8 * gib,
        availableRamBytes: 2 * gib,
        gpus: [
          GpuInfo(name: 'g', backend: GpuBackend.cuda, vramBytes: 4 * gib)
        ]);
    expect(withGpu.usableMemoryBytes, 2 * gib - 256 * mib + 4 * gib);
  });

  test('candidate rule (§2.2) and NodeInfo JSON round-trip', () {
    const hw = HardwareProfile(
        os: 'linux',
        arch: 'x64',
        cpuModel: '',
        cpuCores: 4,
        totalRamBytes: 8 << 30,
        availableRamBytes: 6 << 30);
    final m = LocalModel(
        ref: ModelRef.parse('qwen3:0.6b'), ggufPath: '/x', sizeBytes: 1);
    NodeInfo n({bool worker = true, bool engine = true}) => NodeInfo(
        nodeId: 'a',
        name: 'a',
        host: '1.2.3.4',
        apiPort: kNodeApiPort,
        workerEnabled: worker,
        engineAvailable: engine,
        status: NodeStatus.idle,
        hardware: hw,
        models: [m]);
    expect(n().isCandidateFor(m.ref), isTrue);
    expect(n(worker: false).isCandidateFor(m.ref), isFalse);
    expect(n(engine: false).isCandidateFor(m.ref), isFalse);
    expect(n().isCandidateFor(ModelRef.parse('other')), isFalse);
    expect(NodeInfo.fromJson(n().toJson()).models.single.ref, m.ref);
  });
}
