import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

void main() {
  test('ModelRef parse/format', () {
    expect(ModelRef.parse('qwen3:30b-a3b').toString(), 'qwen3:30b-a3b');
    expect(ModelRef.parse('library/qwen3').toString(), 'qwen3:latest');
    expect(ModelRef.parse('foo/bar:1b').namespace, 'foo');
    expect(() => ModelRef.parse('hf.co/x/y'), throwsFormatException);
  });

  test('candidate rule (§2.2) and NodeInfo JSON round-trip', () {
    const hw = HardwareProfile(
        os: 'linux', arch: 'x64', cpuModel: '', cpuCores: 4, totalRamBytes: 8 << 30, availableRamBytes: 6 << 30);
    final m = LocalModel(ref: ModelRef.parse('qwen3:0.6b'), ggufPath: '/x', sizeBytes: 1);
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
