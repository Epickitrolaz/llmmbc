import 'package:args/args.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:llmmbc_core/src/node/cli_serve.dart';
import 'package:test/test.dart';

ArgResults _parseServe(List<String> args) {
  final parser = ArgParser()..addCommand('serve', buildServeCommandParser());
  return parser.parse(['serve', ...args]).command!;
}

NodeSettings _persisted({
  MemoryBasis basis = MemoryBasis.available,
  double share = 0.5,
  List<String> peers = const ['10.1.2.3:47101', 'peerbox:47101'],
  bool workerEnabled = false,
  bool allowExpertStreaming = false,
}) =>
    NodeSettings(
      nodeId: 'persisted-node',
      name: 'persisted',
      dataDir: '/data',
      apiPort: 48888,
      workerEnabled: workerEnabled,
      manualPeers: peers,
      memoryBasis: basis,
      memoryShare: share,
      allowExpertStreaming: allowExpertStreaming,
    );

void main() {
  group('plain serve keeps persisted settings (#59, #60)', () {
    test('a plain serve keeps memoryBasis=available and memoryShare=0.5', () {
      final persisted = _persisted();
      final request =
          serveRequestFromArgs(_parseServe(const []), environment: const {});
      expect(request.memory.isEmpty, isTrue);
      expect(request.port, isNull,
          reason: 'the default port is not an override');
      expect(request.workerEnabled, isNull);
      expect(request.peers, isNull);
      expect(request.allowExpertStreaming, isNull);

      final next = applyServeRequest(persisted, request);
      expect(next.memoryBasis, MemoryBasis.available);
      expect(next.memoryShare, 0.5);
      expect(next.toJson()['memoryBasis'], 'available');
      expect(next.toJson()['memoryShare'], 0.5);
    });

    test('a plain serve keeps the persisted manual peers', () {
      final persisted = _persisted();
      final request = serveRequestFromArgs(
          _parseServe(const ['--data-dir', '/data']),
          environment: const {});
      final next = applyServeRequest(persisted, request);
      expect(next.manualPeers, ['10.1.2.3:47101', 'peerbox:47101']);
    });

    test('a plain serve keeps name, worker mode and port', () {
      final persisted = _persisted();
      final request = serveRequestFromArgs(
          _parseServe(const ['--data-dir', '/data']),
          environment: const {});
      final next = applyServeRequest(persisted, request);
      expect(next.name, 'persisted');
      expect(next.workerEnabled, isFalse);
      expect(next.apiPort, 48888);
      expect(next.nodeId, 'persisted-node');
    });
  });

  group('explicit serve overrides', () {
    test('flags override memory, name, worker and port', () {
      final persisted = _persisted(workerEnabled: true);
      final request = serveRequestFromArgs(
        _parseServe(const [
          '--memory-basis',
          'total',
          '--memory-share',
          '0.9',
          '--name',
          'cli-node',
          '--no-worker',
          '--port',
          '49000',
        ]),
        environment: const {},
      );
      final next = applyServeRequest(persisted, request);
      expect(next.memoryBasis, MemoryBasis.total);
      expect(next.memoryShare, 0.9);
      expect(next.name, 'cli-node');
      expect(next.workerEnabled, isFalse);
      expect(next.apiPort, 49000);
    });

    test('explicit peers are merged with persisted peers, de-duplicated', () {
      final persisted = _persisted();
      final request = serveRequestFromArgs(
        _parseServe(const [
          '--peer',
          '10.0.0.9:47101',
          '--peer',
          'peerbox:47101',
        ]),
        environment: const {},
      );
      final next = applyServeRequest(persisted, request);
      expect(next.manualPeers, [
        '10.1.2.3:47101',
        'peerbox:47101',
        '10.0.0.9:47101',
      ]);
    });

    test('LLMMBC_PEERS is merged too', () {
      final persisted = _persisted();
      final request = serveRequestFromArgs(
        _parseServe(const []),
        environment: const {
          'LLMMBC_PEERS': 'new:47101, peerbox:47101',
        },
      );
      final next = applyServeRequest(persisted, request);
      expect(next.manualPeers, [
        '10.1.2.3:47101',
        'peerbox:47101',
        'new:47101',
      ]);
    });

    test('environment overrides apply only when present', () {
      final persisted = _persisted(workerEnabled: true);
      final request = serveRequestFromArgs(
        _parseServe(const []),
        environment: const {
          'LLMMBC_MEMORY_BASIS': 'total',
          'LLMMBC_MEMORY_SHARE': '0.6',
          'LLMMBC_NAME': 'env-node',
          'LLMMBC_WORKER': '0',
        },
      );
      final next = applyServeRequest(persisted, request);
      expect(next.memoryBasis, MemoryBasis.total);
      expect(next.memoryShare, 0.6);
      expect(next.name, 'env-node');
      expect(next.workerEnabled, isFalse);
    });

    test('overriding the basis alone keeps the persisted share', () {
      final persisted = _persisted();
      final request = serveRequestFromArgs(
        _parseServe(const ['--memory-basis', 'total']),
        environment: const {},
      );
      final next = applyServeRequest(persisted, request);
      expect(next.memoryBasis, MemoryBasis.total);
      expect(next.memoryShare, 0.5);
    });

    test('a specified port overrides the persisted one', () {
      final persisted = _persisted();
      final request = serveRequestFromArgs(
        _parseServe(const ['--port', '0']),
        environment: const {},
      );
      expect(applyServeRequest(persisted, request).apiPort, 0);
    });

    test('a plain serve keeps the persisted expert-streaming setting', () {
      final persisted = _persisted(allowExpertStreaming: true);
      final request = serveRequestFromArgs(
        _parseServe(const []),
        environment: const {},
      );
      expect(request.allowExpertStreaming, isNull);
      expect(
          applyServeRequest(persisted, request).allowExpertStreaming, isTrue);
    });

    test('--allow-expert-streaming / --no-... override the setting', () {
      final enabled = applyServeRequest(
        _persisted(),
        serveRequestFromArgs(
            _parseServe(const ['--allow-expert-streaming']),
            environment: const {}),
      );
      expect(enabled.allowExpertStreaming, isTrue);

      final disabled = applyServeRequest(
        _persisted(allowExpertStreaming: true),
        serveRequestFromArgs(
            _parseServe(const ['--no-allow-expert-streaming']),
            environment: const {}),
      );
      expect(disabled.allowExpertStreaming, isFalse);
    });

    test('LLMMBC_EXPERT_STREAMING=1|0 overrides the setting', () {
      final enabled = applyServeRequest(
        _persisted(),
        serveRequestFromArgs(_parseServe(const []),
            environment: const {'LLMMBC_EXPERT_STREAMING': '1'}),
      );
      expect(enabled.allowExpertStreaming, isTrue);

      final disabled = applyServeRequest(
        _persisted(allowExpertStreaming: true),
        serveRequestFromArgs(_parseServe(const []),
            environment: const {'LLMMBC_EXPERT_STREAMING': '0'}),
      );
      expect(disabled.allowExpertStreaming, isFalse);
    });

    test('a flag wins over LLMMBC_EXPERT_STREAMING', () {
      final request = serveRequestFromArgs(
        _parseServe(const ['--no-allow-expert-streaming']),
        environment: const {'LLMMBC_EXPERT_STREAMING': '1'},
      );
      expect(request.allowExpertStreaming, isFalse);
    });

    test('rejects an invalid LLMMBC_EXPERT_STREAMING value', () {
      expect(
        () => serveRequestFromArgs(_parseServe(const []),
            environment: const {'LLMMBC_EXPERT_STREAMING': 'maybe'}),
        throwsFormatException,
      );
    });

    test('rejects an invalid port or memory value', () {
      expect(() => serveRequestFromArgs(_parseServe(const ['--port', '70000'])),
          throwsFormatException);
      expect(() => serveRequestFromArgs(_parseServe(const ['--port', 'abc'])),
          throwsFormatException);
      expect(
          () => serveRequestFromArgs(
              _parseServe(const ['--memory-share', '1.5'])),
          throwsFormatException);
    });
  });
}
