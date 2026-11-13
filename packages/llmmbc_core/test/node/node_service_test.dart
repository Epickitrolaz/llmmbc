import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

import 'fakes.dart';

class Harness {
  final LocalNodeService service;
  final FakeEngine engine;
  final FakePlanner planner;
  final FakeNodeClient client;
  final FakeDiscovery discovery;
  final FakeHardwareProbe probe;
  final ModelStore store;
  final Directory dir;

  Harness({
    required this.service,
    required this.engine,
    required this.planner,
    required this.client,
    required this.discovery,
    required this.probe,
    required this.store,
    required this.dir,
  });
}

Harness buildHarness({
  String selfId = 'self',
  String selfName = 'self',
  HardwareProfile? hardware,
  List<LocalModel> models = const [],
  List<NodeInfo> peers = const [],
  bool engineAvailable = true,
  bool workerEnabled = true,
  Duration idle = kSessionIdleTimeout,
  Duration modelRefreshInterval = const Duration(seconds: 10),
  double memoryShare = kDefaultMemoryShare,
  MemoryBasis memoryBasis = MemoryBasis.total,
  FakeEngine? engine,
  FakePlanner? planner,
  FakeNodeClient? client,
  FakeDiscovery? discoveryFake,
  ModelStore? modelStore,
  DateTime Function()? now,
}) {
  final dir = Directory.systemTemp.createTempSync('llmmbc_node_test');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });
  final settings = NodeSettings(
    nodeId: selfId,
    name: selfName,
    dataDir: dir.path,
    apiPort: 0,
    workerEnabled: workerEnabled,
    memoryShare: memoryShare,
    memoryBasis: memoryBasis,
  );
  final fakeEngine = engine ?? FakeEngine();
  final fakePlanner = planner ?? FakePlanner();
  final fakeClient = client ?? FakeNodeClient();
  final fakeDiscovery = discoveryFake ?? FakeDiscovery(peers.toList());
  final fakeProbe = FakeHardwareProbe(hardware ?? hw());
  final store = modelStore ?? FakeModelStore(models.toList());
  final service = LocalNodeService.internal(
    settings: settings,
    hardwareProbe: fakeProbe,
    modelStore: store,
    discovery: fakeDiscovery,
    client: fakeClient,
    locator: FakeEngineLocator(isAvailable: engineAvailable),
    engine: fakeEngine,
    planner: fakePlanner,
    settingsPath: '${dir.path}/settings.json',
    now: now,
    sessionIdleTimeout: idle,
    modelRefreshInterval: modelRefreshInterval,
  );
  addTearDown(service.stop);
  return Harness(
    service: service,
    engine: fakeEngine,
    planner: fakePlanner,
    client: fakeClient,
    discovery: fakeDiscovery,
    probe: fakeProbe,
    store: store,
    dir: dir,
  );
}

Matcher llmmbcError(String code) =>
    isA<LlmmbcException>().having((e) => e.code, 'code', code);

Future<void> waitUntil(bool Function() predicate,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('startup', () {
    test('emits the §2.1 phases in order', () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      final phases = <String>[];
      final sub = h.service.startupPhase.listen(phases.add);
      await h.service.start();
      await Future<void>.delayed(Duration.zero);
      expect(phases,
          ['settings', 'hardware', 'models', 'api', 'discovery', 'ready']);
      expect(h.service.self.nodeId, 'self');
      expect(h.service.self.apiPort, greaterThan(0));
      expect(h.probe.scans, 1);
      await sub.cancel();
    });

    test('create persists a nodeId and defaults the name to the hostname',
        () async {
      final dir = Directory.systemTemp.createTempSync('llmmbc_settings_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/settings.json';
      final first = await LocalNodeService.create(
          settingsPath: path, defaultDataDir: dir.path);
      final id = first.settings.nodeId;
      expect(id, isNotEmpty);
      expect(File(path).existsSync(), isTrue);
      final second = await LocalNodeService.create(
          settingsPath: path, defaultDataDir: dir.path);
      expect(second.settings.nodeId, id);
      expect(second.settings.name, Platform.localHostname);
      final json = File(path).readAsStringSync();
      expect(json, contains(id));
    });

    test('clientOnly forces worker mode off', () async {
      final dir =
          Directory.systemTemp.createTempSync('llmmbc_client_only_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = await LocalNodeService.create(
        settingsPath: '${dir.path}/settings.json',
        defaultDataDir: dir.path,
        platform: const PlatformHooks(clientOnly: true),
      );
      expect(service.settings.workerEnabled, isFalse);
      expect(service.self.workerEnabled, isFalse);
    });
  });

  group('cluster models / eligibility', () {
    test('self is a candidate when worker, engine and model are present',
        () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      final cluster = h.service.clusterModels();
      expect(cluster, hasLength(1));
      expect(cluster.single.ref, ModelRef.parse('qwen3:0.6b'));
      expect(cluster.single.candidates.map((c) => c.nodeId), ['self']);
    });

    test('worker off removes the model from the cluster union', () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      await h.service
          .updateSettings(h.service.settings.copyWith(workerEnabled: false));
      expect(h.service.clusterModels(), isEmpty);
      expect(
          h.service.self.isCandidateFor(ModelRef.parse('qwen3:0.6b')), isFalse);
    });

    test('engine unavailable yields a model with no candidates', () async {
      final h = buildHarness(
          models: [localModel('qwen3:0.6b')], engineAvailable: false);
      await h.service.start();
      final cluster = h.service.clusterModels();
      expect(cluster, hasLength(1));
      expect(cluster.single.candidates, isEmpty);
      expect(
          h.service.self.isCandidateFor(ModelRef.parse('qwen3:0.6b')), isFalse);
    });

    test('missing model yields no cluster entry', () async {
      final h = buildHarness();
      await h.service.start();
      expect(h.service.clusterModels(), isEmpty);
    });
  });

  group('runtime model catalog (#33)', () {
    test('model added to the injected store is visible without restart',
        () async {
      final store = FakeModelStore();
      final h = buildHarness(modelStore: store);
      await h.service.start();
      expect(h.service.self.models, isEmpty);
      expect(h.service.clusterModels(), isEmpty);

      store.stored = [localModel('qwen3:0.6b')];
      await h.service.refreshModels(force: true);
      expect(h.service.self.models.single.ref, ModelRef.parse('qwen3:0.6b'));
      expect(h.service.clusterModels().single.candidates.map((c) => c.nodeId),
          ['self']);

      // No explicit refresh: chat() must refresh before its candidate check.
      store.stored = [...store.stored, localModel('a:1b')];
      final deltas = await h.service.chat(
          ModelRef.parse('a:1b'), [const ChatMessage('user', 'hi')]).toList();
      expect(deltas.map((d) => d.content).join(), 'Hello world');
      expect(h.service.self.models.map((m) => m.ref),
          contains(ModelRef.parse('a:1b')));
    });

    test('periodic rescan picks up a store mutation from another process',
        () async {
      final store = FakeModelStore();
      final h = buildHarness(
        modelStore: store,
        modelRefreshInterval: const Duration(milliseconds: 100),
      );
      await h.service.start();
      store.stored = [localModel('qwen3:0.6b')];

      await waitUntil(() => h.service.self.models.isNotEmpty);
      expect(h.service.self.models.single.ref, ModelRef.parse('qwen3:0.6b'));
      expect(
          h.service.clusterModels().single.ref, ModelRef.parse('qwen3:0.6b'));
    });

    test('a CLI-style pull into the node data dir is advertised (#33)',
        () async {
      final dataDir = Directory.systemTemp.createTempSync('llmmbc_pull_test');
      addTearDown(() => dataDir.deleteSync(recursive: true));
      final store = FileModelStore(dataDir.path);
      final h = buildHarness(
        modelStore: store,
        modelRefreshInterval: const Duration(milliseconds: 100),
      );
      await h.service.start();
      expect(h.service.self.models, isEmpty);

      // Simulate `llmmbc_node pull qwen3:0.6b --data-dir <same dir>`.
      final hex = 'a' * 64;
      final blob = File('${dataDir.path}/models/blobs/sha256-$hex')
        ..createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      expect(blob.existsSync(), isTrue);
      File('${dataDir.path}/models/manifests/library/qwen3/0.6b.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'layers': [
            {'mediaType': kMediaTypeModel, 'digest': 'sha256:$hex', 'size': 4}
          ]
        }));

      await waitUntil(() => h.service.self.models
          .any((m) => m.ref == ModelRef.parse('qwen3:0.6b')));

      final client = HttpNodeClient();
      try {
        final info = await client.info(Uri(
            scheme: 'http', host: '127.0.0.1', port: h.service.self.apiPort));
        expect(info.models.single.ref, ModelRef.parse('qwen3:0.6b'));
      } finally {
        client.close();
      }
    });
  });

  group('memory budget (§2.5)', () {
    test('defaults to total basis and advertises the budget in NodeInfo',
        () async {
      final hardware = hw(total: 16 << 30, available: 4 << 30);
      final h =
          buildHarness(hardware: hardware, models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      final expected =
          hardware.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare);
      expect(expected, ((16 << 30) * kDefaultMemoryShare).floor());
      expect(h.service.self.memoryBudgetBytes, expected);

      final client = HttpNodeClient();
      addTearDown(client.close);
      final info = await client.info(
          Uri(scheme: 'http', host: '127.0.0.1', port: h.service.self.apiPort));
      expect(info.memoryBudgetBytes, expected);
      expect(info.effectiveBudgetBytes, expected);
    });

    test('available basis advertises a smaller budget and rpc/start returns it',
        () async {
      final hardware = hw(total: 16 << 30, available: 4 << 30);
      final h = buildHarness(
        hardware: hardware,
        models: [localModel('qwen3:0.6b')],
        memoryBasis: MemoryBasis.available,
        memoryShare: 0.5,
      );
      await h.service.start();
      final expected = hardware.memoryBudgetBytes(MemoryBasis.available, 0.5);
      expect(h.service.self.memoryBudgetBytes, expected);
      expect(expected,
          lessThan(hardware.memoryBudgetBytes(MemoryBasis.total, 0.5)));

      final result = await h.service.handleRpcStart(
        sessionId: 's1',
        model: ModelRef.parse('qwen3:0.6b'),
        coordinatorId: 'c',
      );
      expect(result.budgetBytes, expected);
    });

    test('the coordinator plan uses its own advertised budget', () async {
      final hardware = hw(total: 16 << 30, available: 4 << 30);
      final h =
          buildHarness(hardware: hardware, models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      final plan = h.engine.lastPlan;
      expect(plan, isNotNull);
      expect(plan!.nodes.single.nodeId, 'self');
      expect(plan.nodes.single.budgetBytes, h.service.self.memoryBudgetBytes);
    });

    test('prefers the largest advertised budget over raw hardware', () async {
      final h = buildHarness(
        hardware: hw(total: 16 << 30, available: 4 << 30),
        models: [localModel('qwen3:0.6b')],
        peers: [
          // Small machine that lends a lot by configuration.
          nodeInfo('advertised',
              apiPort: 50001,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 8 << 30, available: 1 << 30),
              memoryBudgetBytes: 32 << 30),
          // Larger machine without an advertised budget (older peer).
          nodeInfo('legacy',
              apiPort: 50002,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 64 << 30, available: 32 << 30)),
        ],
      );
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(h.client.chatBases.single.port, 50001);
    });

    test('falls back to usable memory for peers without a budget', () async {
      final h = buildHarness(
        hardware: hw(total: 16 << 30, available: 4 << 30),
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('advertised',
              apiPort: 50001,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 2 << 30, available: 1 << 30),
              memoryBudgetBytes: 30 << 30),
          nodeInfo('legacy',
              apiPort: 50002,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 64 << 30, available: 32 << 30)),
        ],
      );
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(h.client.chatBases.single.port, 50002);
    });

    test('clusterModels orders candidates by effective budget', () async {
      final h = buildHarness(
        hardware: hw(total: 8 << 30, available: 1 << 30),
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('legacy',
              apiPort: 50001,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 64 << 30, available: 32 << 30)),
          nodeInfo('advertised',
              apiPort: 50002,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 2 << 30, available: 1 << 30),
              memoryBudgetBytes: 48 << 30),
        ],
      );
      await h.service.start();
      final cluster = h.service.clusterModels();
      expect(cluster.single.candidates.map((c) => c.nodeId),
          ['advertised', 'legacy', 'self']);
    });

    test('updateSettings recomputes the budget and emits changed', () async {
      final hardware = hw(total: 16 << 30, available: 4 << 30);
      final h =
          buildHarness(hardware: hardware, models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      final before = h.service.self.memoryBudgetBytes;
      final events = <void>[];
      final sub = h.service.changed.listen(events.add);
      await h.service.updateSettings(h.service.settings
          .copyWith(memoryBasis: MemoryBasis.available, memoryShare: 0.5));
      await Future<void>.delayed(Duration.zero);
      expect(h.service.self.memoryBudgetBytes,
          hardware.memoryBudgetBytes(MemoryBasis.available, 0.5));
      expect(h.service.self.memoryBudgetBytes, lessThan(before));
      expect(events, isNotEmpty);
      await sub.cancel();
    });

    test('migrates a v1 settings file and rewrites it on first start',
        () async {
      final dir = Directory.systemTemp.createTempSync('llmmbc_migration_test');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // ignore
        }
      });
      final path = '${dir.path}/settings.json';
      File(path).writeAsStringSync(jsonEncode({
        'nodeId': 'legacy-node',
        'name': 'legacy',
        'dataDir': dir.path,
        'workerEnabled': false,
        'memoryShare': 0.8,
      }));
      final service = await LocalNodeService.create(
          settingsPath: path, defaultDataDir: dir.path);
      addTearDown(service.stop);
      expect(service.settings.memoryShare, kDefaultMemoryShare);
      expect(service.settings.memoryBasis, MemoryBasis.total);
      expect(service.settings.workerEnabled, isFalse);
      final persisted =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(persisted['settingsVersion'], kSettingsVersion);
      expect(persisted['memoryBasis'], 'total');
      expect((persisted['memoryShare'] as num).toDouble(), kDefaultMemoryShare);
    });
  });

  group('coordinator selection', () {
    test('handles the request locally when self has the most memory', () async {
      final h = buildHarness(
        hardware: hw(total: 16 << 30, available: 12 << 30),
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('remote',
              apiPort: 50001, hardware: hw(total: 8 << 30, available: 2 << 30)),
        ],
      );
      await h.service.start();
      final deltas = await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(deltas.map((d) => d.content).join(), 'Hello world');
      expect(deltas.last.finishReason, 'stop');
      expect(deltas.last.servedBy, 'self');
      expect(h.engine.coordinatorStarts, 1);
      expect(h.client.chatBases, isEmpty);
      expect(h.service.currentSession?.coordinatorId, 'self');
    });

    test('routes to the remote candidate with the largest usable memory',
        () async {
      final h = buildHarness(
        hardware: hw(total: 8 << 30, available: 1 << 30),
        peers: [
          nodeInfo('small',
              apiPort: 50001,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 8 << 30, available: 2 << 30)),
          nodeInfo('big',
              apiPort: 50002,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 32 << 30, available: 24 << 30)),
        ],
      );
      await h.service.start();
      final deltas = await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(deltas.map((d) => d.content).join(), 'remote answer');
      expect(h.client.chatBases, hasLength(1));
      expect(h.client.chatBases.single.port, 50002);
      expect(h.engine.coordinatorStarts, 0);
    });

    test('breaks equal-memory ties by the smallest nodeId', () async {
      final shared = hw(total: 8 << 30, available: 4 << 30);
      final h = buildHarness(
        hardware: hw(total: 8 << 30, available: 1 << 30),
        peers: [
          nodeInfo('zzz',
              apiPort: 50001,
              models: [localModel('qwen3:0.6b')],
              hardware: shared),
          nodeInfo('aaa',
              apiPort: 50002,
              models: [localModel('qwen3:0.6b')],
              hardware: shared),
        ],
      );
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(h.client.chatBases.single.port, 50002);
    });

    test('throws no_candidates when nobody can run the model', () async {
      final h = buildHarness(
          engineAvailable: false, models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      await expectLater(
        h.service.chat(ModelRef.parse('qwen3:0.6b'),
            [const ChatMessage('user', 'hi')]).toList(),
        throwsA(llmmbcError('no_candidates')),
      );
    });
  });

  group('worker rpc endpoints', () {
    test('rejects not-candidate nodes with not_candidate', () async {
      final workerOff = buildHarness(
          models: [localModel('qwen3:0.6b')], workerEnabled: false);
      await workerOff.service.start();
      await expectLater(
        workerOff.service.handleRpcStart(
          sessionId: 's1',
          model: ModelRef.parse('qwen3:0.6b'),
          coordinatorId: 'c',
        ),
        throwsA(llmmbcError('not_candidate')),
      );

      final missingModel = buildHarness();
      await missingModel.service.start();
      await expectLater(
        missingModel.service.handleRpcStart(
          sessionId: 's1',
          model: ModelRef.parse('qwen3:0.6b'),
          coordinatorId: 'c',
        ),
        throwsA(llmmbcError('not_candidate')),
      );

      final noEngine = buildHarness(
          models: [localModel('qwen3:0.6b')], engineAvailable: false);
      await noEngine.service.start();
      await expectLater(
        noEngine.service.handleRpcStart(
          sessionId: 's1',
          model: ModelRef.parse('qwen3:0.6b'),
          coordinatorId: 'c',
        ),
        throwsA(llmmbcError('not_candidate')),
      );
    });

    test(
        'starts one rpc worker, is idempotent for the same session and busy otherwise',
        () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      final result = await h.service.handleRpcStart(
        sessionId: 's1',
        model: ModelRef.parse('qwen3:0.6b'),
        coordinatorId: 'c',
      );
      expect(result.port, kRpcServerPort);
      expect(result.budgetBytes, greaterThan(0));
      expect(h.engine.rpcStarts, 1);
      expect(h.service.self.status, NodeStatus.worker);

      final again = await h.service.handleRpcStart(
        sessionId: 's1',
        model: ModelRef.parse('qwen3:0.6b'),
        coordinatorId: 'c',
      );
      expect(again.port, result.port);
      expect(h.engine.rpcStarts, 1);

      await expectLater(
        h.service.handleRpcStart(
          sessionId: 's2',
          model: ModelRef.parse('qwen3:0.6b'),
          coordinatorId: 'c',
        ),
        throwsA(llmmbcError('busy')),
      );

      await h.service.handleRpcStop('s1');
      expect(h.engine.rpcStops, 1);
      expect(h.service.currentSession, isNull);
      expect(h.service.self.status, NodeStatus.idle);
    });

    test('serializes concurrent rpc starts: one wins, the other is busy (#17)',
        () async {
      final engine = FakeEngine()..startRpcGate = Completer<void>();
      final h = buildHarness(
        models: [localModel('qwen3:0.6b')],
        engine: engine,
      );
      await h.service.start();
      final model = ModelRef.parse('qwen3:0.6b');
      final first = h.service.handleRpcStart(
          sessionId: 'sess-A', model: model, coordinatorId: 'cA');
      final second = h.service.handleRpcStart(
          sessionId: 'sess-B', model: model, coordinatorId: 'cB');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      engine.startRpcGate!.complete();

      final results = await Future.wait([
        first.then<Object>((value) => value, onError: (Object e) => e),
        second.then<Object>((value) => value, onError: (Object e) => e),
      ]);
      var successes = 0;
      final errors = <Object>[];
      for (final result in results) {
        if (result is LlmmbcException) {
          errors.add(result);
        } else {
          successes++;
        }
      }
      expect(successes, 1);
      expect(errors, hasLength(1));
      expect((errors.single as LlmmbcException).code, 'busy');
      expect(engine.rpcStarts, 1);
      expect(engine.maxConcurrentRpcStarts, 1);
      expect(h.service.currentSession?.sessionId, 'sess-A');
    });

    test('disabling worker mode stops the rpc worker immediately', () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      await h.service.handleRpcStart(
        sessionId: 's1',
        model: ModelRef.parse('qwen3:0.6b'),
        coordinatorId: 'c',
      );
      await h.service
          .updateSettings(h.service.settings.copyWith(workerEnabled: false));
      expect(h.engine.rpcStops, 1);
      expect(h.service.currentSession, isNull);
      expect(h.engine.rpcWorkerRunning, isFalse);
    });

    test('refuses to become a worker while coordinating', () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      await expectLater(
        h.service.handleRpcStart(
          sessionId: 'other',
          model: ModelRef.parse('qwen3:0.6b'),
          coordinatorId: 'c',
        ),
        throwsA(llmmbcError('busy')),
      );
    });
  });

  group('coordinator session lifecycle', () {
    test('warm session reuse does not re-scan discovery (#19)', () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      final model = ModelRef.parse('qwen3:0.6b');
      await h.service.chat(model, [const ChatMessage('user', 'hi')]).toList();
      expect(h.discovery.scans, 1);
      await h.service
          .chat(model, [const ChatMessage('user', 'again')]).toList();
      await h.service
          .chat(model, [const ChatMessage('user', 'again')]).toList();
      expect(h.discovery.scans, 1);
      expect(h.engine.coordinatorStarts, 1);
    });

    test('idle teardown cannot stop a newly started session (#18)', () async {
      final engine = FakeEngine()
        ..stopCoordinatorGate = Completer<void>()
        ..stopCoordinatorEntered = Completer<void>();
      final h = buildHarness(
        hardware: hw(total: 16 << 30, available: 12 << 30),
        models: [localModel('qwen3:0.6b')],
        engine: engine,
        idle: const Duration(milliseconds: 250),
      );
      await h.service.start();
      final model = ModelRef.parse('qwen3:0.6b');
      await h.service.chat(model, [const ChatMessage('user', 'hi')]).toList();

      // Wait for the idle timer to enter the teardown, then start a new chat
      // while the old teardown is still blocked.
      await engine.stopCoordinatorEntered!.future
          .timeout(const Duration(seconds: 3));
      final next =
          h.service.chat(model, [const ChatMessage('user', 'again')]).toList();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.coordinatorStarts, 1);

      engine.stopCoordinatorGate!.complete();
      final deltas = await next.timeout(const Duration(seconds: 3));
      expect(deltas.map((d) => d.content).join(), 'Hello world');
      expect(h.service.currentSession, isNotNull);
      expect(engine.coordinatorRunning, isTrue);
      expect(engine.coordinatorStarts, 2);
      expect(engine.coordinatorStops, 1);
    });

    test(
        'plans with workers, starts the engine, proxies SSE and expires after idle',
        () async {
      final h = buildHarness(
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('worker',
              apiPort: 50001,
              models: [localModel('qwen3:0.6b')],
              hardware: hw(total: 8 << 30, available: 4 << 30)),
        ],
        idle: const Duration(milliseconds: 300),
      );
      await h.service.start();
      final deltas = await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(deltas.map((d) => d.content).join(), 'Hello world');
      expect(h.client.startRpcCalls, hasLength(1));
      expect(h.client.startRpcCalls.single.sessionId, isNotEmpty);
      expect(h.engine.coordinatorStarts, 1);
      expect(h.engine.lastPlan!.nodes, hasLength(2));
      final session = h.service.currentSession!;
      expect(session.workerIds, ['worker']);
      expect(session.coordinatorId, 'self');
      expect(session.plan, isNotNull);
      expect(h.service.self.status, NodeStatus.coordinator);

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(h.service.currentSession, isNull);
      expect(h.engine.coordinatorStops, greaterThanOrEqualTo(1));
      expect(h.client.stopRpcCalls.map((c) => c.base.port), contains(50001));
      expect(h.service.self.status, NodeStatus.idle);
    });

    test('restarts the session when the model changes', () async {
      final h = buildHarness(models: [localModel('a:1b'), localModel('b:1b')]);
      await h.service.start();
      await h.service.chat(
          ModelRef.parse('a:1b'), [const ChatMessage('user', 'hi')]).toList();
      final first = h.service.currentSession!.sessionId;
      await h.service.chat(
          ModelRef.parse('b:1b'), [const ChatMessage('user', 'hi')]).toList();
      final second = h.service.currentSession!.sessionId;
      expect(second, isNot(first));
      expect(h.service.currentSession!.model, ModelRef.parse('b:1b'));
      expect(h.engine.coordinatorStarts, 2);
      expect(h.engine.coordinatorStops, 1);
    });

    test('restarts the session when the candidate set changes', () async {
      final h = buildHarness(models: [localModel('qwen3:0.6b')]);
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      final first = h.service.currentSession!.sessionId;

      h.discovery.peerList.add(
        nodeInfo(
          'late',
          apiPort: 50001,
          models: [localModel('qwen3:0.6b')],
          hardware: hw(total: 8 << 30, available: 1 << 30),
        ),
      );
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      final second = h.service.currentSession!.sessionId;
      expect(second, isNot(first));
      expect(h.service.currentSession!.workerIds, ['late']);
      expect(h.engine.coordinatorStarts, 2);
    });

    test('does not fit stops workers and reports does_not_fit', () async {
      final planner = FakePlanner()..fail = true;
      final h = buildHarness(
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('worker', apiPort: 50001, models: [localModel('qwen3:0.6b')])
        ],
        planner: planner,
      );
      await h.service.start();
      await expectLater(
        h.service.chat(ModelRef.parse('qwen3:0.6b'),
            [const ChatMessage('user', 'hi')]).toList(),
        throwsA(llmmbcError('does_not_fit')),
      );
      expect(h.client.stopRpcCalls, hasLength(1));
      expect(h.engine.coordinatorStarts, 0);
      expect(h.service.currentSession, isNull);
    });

    test('drops a worker that fails to start', () async {
      final failing = FakeNodeClient();
      final h = buildHarness(
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo(
            'bad',
            apiPort: 50003,
            models: [localModel('qwen3:0.6b')],
            hardware: hw(total: 8 << 30, available: 1 << 30),
          ),
        ],
        client: failing,
      );
      await h.service.start();
      failing.startRpcError = LlmmbcException('busy', 'nope');
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();
      expect(failing.startRpcCalls, hasLength(1));
      expect(h.service.currentSession!.workerIds, isEmpty);
      expect(h.service.currentSession!.coordinatorId, 'self');
    });

    test(
        'uses the rpc port returned by each worker, keeping endpoints distinct',
        () async {
      final client = FakeNodeClient()
        ..rpcPortByApiPort[50001] = 51001
        ..rpcPortByApiPort[50002] = 51002;
      final h = buildHarness(
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('w1', apiPort: 50001, models: [localModel('qwen3:0.6b')]),
          nodeInfo('w2', apiPort: 50002, models: [localModel('qwen3:0.6b')]),
        ],
        client: client,
      );
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();

      final endpoints = [
        for (final node in h.engine.lastPlan!.nodes)
          if (node.rpcEndpoint != null) node.rpcEndpoint!
      ];
      expect(endpoints, ['127.0.0.1:51001', '127.0.0.1:51002']);
      expect(endpoints.toSet(), hasLength(2));
      expect(h.service.currentSession!.workerIds, ['w1', 'w2']);
    });

    test('drops a worker that reports an endpoint already in the plan (#36)',
        () async {
      final client = FakeNodeClient()
        ..rpcPortByApiPort[50001] = 51000
        ..rpcPortByApiPort[50002] = 51000;
      final h = buildHarness(
        models: [localModel('qwen3:0.6b')],
        peers: [
          nodeInfo('w1', apiPort: 50001, models: [localModel('qwen3:0.6b')]),
          nodeInfo('w2', apiPort: 50002, models: [localModel('qwen3:0.6b')]),
        ],
        client: client,
      );
      await h.service.start();
      await h.service.chat(ModelRef.parse('qwen3:0.6b'),
          [const ChatMessage('user', 'hi')]).toList();

      final endpoints = [
        for (final node in h.engine.lastPlan!.nodes)
          if (node.rpcEndpoint != null) node.rpcEndpoint!
      ];
      expect(endpoints, ['127.0.0.1:51000']);
      expect(h.service.currentSession!.workerIds, ['w1']);
      // The dropped worker is told to stop so it does not leak an rpc-server.
      expect(client.stopRpcCalls.map((c) => c.base.port), contains(50002));
    });
  });
}
