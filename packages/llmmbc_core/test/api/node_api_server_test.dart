import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

import '../node/fakes.dart';

Uri baseOf(LocalNodeService service) =>
    Uri(scheme: 'http', host: '127.0.0.1', port: service.self.apiPort);

void main() {
  test('GET /v1/node, /v1/peers, /v1/models and /v1/session round-trip',
      () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
          nodeId: 'self', name: 'self', dataDir: dir.path, apiPort: 0),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore([localModel('qwen3:0.6b')]),
      discovery: FakeDiscovery([nodeInfo('remote', apiPort: 50001)]),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();
    final client = HttpNodeClient(timeout: const Duration(seconds: 5));
    final base = baseOf(service);

    final info = await client.info(base);
    expect(info.nodeId, 'self');
    expect(info.hardware.cpuCores, 8);

    final peers = await client.peers(base);
    expect(peers.map((p) => p.nodeId), containsAll(['self', 'remote']));
    expect(peers.singleWhere((p) => p.nodeId == 'self').isSelf, isTrue);
    expect(peers.singleWhere((p) => p.nodeId == 'remote').isSelf, isFalse);

    final raw = await http.get(base.resolve('/v1/peers'));
    final rawPeers =
        (jsonDecode(raw.body) as Map<String, dynamic>)['peers'] as List;
    final rawSelf = rawPeers
        .cast<Map<String, dynamic>>()
        .singleWhere((p) => p['nodeId'] == 'self');
    final rawRemote = rawPeers
        .cast<Map<String, dynamic>>()
        .singleWhere((p) => p['nodeId'] == 'remote');
    expect(rawSelf['isSelf'], isTrue);
    expect(rawRemote['isSelf'], isNot(true));

    final models = await service.models.list();
    expect(models.single.ref, ModelRef.parse('qwen3:0.6b'));

    expect(await client.session(base), isNull);
  });

  test('rpc start/stop round-trip and busy error mapping', () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
          nodeId: 'self', name: 'self', dataDir: dir.path, apiPort: 0),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore([localModel('qwen3:0.6b')]),
      discovery: FakeDiscovery(),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();
    final client = HttpNodeClient(timeout: const Duration(seconds: 5));
    final base = baseOf(service);
    final model = ModelRef.parse('qwen3:0.6b');

    final started = await client.startRpc(base,
        sessionId: 's1', model: model, coordinatorId: 'c');
    expect(started.port, kRpcServerPort);
    expect(started.budgetBytes, greaterThan(0));

    final session = await client.session(base);
    expect(session, isNotNull);
    expect(session!.sessionId, 's1');
    expect(session.model, model);

    await expectLater(
      client.startRpc(base, sessionId: 's2', model: model, coordinatorId: 'c'),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'busy')
          .having((e) => e.httpStatus, 'httpStatus', 409)),
    );

    await client.stopRpc(base, 's1');
    expect(await client.session(base), isNull);
  });

  test('chat streams SSE and serves non-streaming JSON', () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
          nodeId: 'self', name: 'self', dataDir: dir.path, apiPort: 0),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore([localModel('qwen3:0.6b')]),
      discovery: FakeDiscovery(),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();
    final client = HttpNodeClient(timeout: const Duration(seconds: 5));
    final base = baseOf(service);

    final streamed = await client.chat(base, ModelRef.parse('qwen3:0.6b'),
        [const ChatMessage('user', 'hi')]).toList();
    expect(streamed.map((d) => d.content).join(), 'Hello world');
    expect(streamed.last.finishReason, 'stop');
    expect(streamed.last.servedBy, 'self');

    final response = await http.post(
      base.resolve('/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': 'qwen3:0.6b',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'stream': false,
      }),
    );
    expect(response.statusCode, 200);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = json['choices'] as List;
    expect((choices.single as Map)['message']['content'], 'Hello world');
  });

  test('protocol headers, CORS preflight and error JSON', () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
          nodeId: 'self', name: 'self', dataDir: dir.path, apiPort: 0),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore([localModel('qwen3:0.6b')]),
      discovery: FakeDiscovery(),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();
    final base = baseOf(service);

    final info = await http.get(base.resolve('/v1/node'));
    expect(info.statusCode, 200);
    expect(info.headers['x-llmmbc-protocol'], '1');
    expect(info.headers['x-llmmbc-node'], 'self');
    expect(info.headers['access-control-allow-origin'], '*');

    final preflight =
        await http.Request('OPTIONS', base.resolve('/v1/node')).send();
    expect(preflight.statusCode, HttpStatus.noContent);
    await preflight.stream.drain<void>();

    final missing = await http.get(base.resolve('/v1/nope'));
    expect(missing.statusCode, 404);
    final missingBody = jsonDecode(missing.body) as Map<String, dynamic>;
    expect(missingBody['error']['code'], 'not_found');

    final bad = await http.post(
      base.resolve('/v1/rpc/start'),
      headers: {'Content-Type': 'application/json'},
      body: '{}',
    );
    expect(bad.statusCode, 400);
    expect((jsonDecode(bad.body) as Map<String, dynamic>)['error']['code'],
        'bad_request');
  });

  test('worker-disabled nodes answer 403 not_candidate', () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
        nodeId: 'self',
        name: 'self',
        dataDir: dir.path,
        apiPort: 0,
        workerEnabled: false,
      ),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore([localModel('qwen3:0.6b')]),
      discovery: FakeDiscovery(),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();
    final client = HttpNodeClient(timeout: const Duration(seconds: 5));
    await expectLater(
      client.startRpc(
        baseOf(service),
        sessionId: 's1',
        model: ModelRef.parse('qwen3:0.6b'),
        coordinatorId: 'c',
      ),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'not_candidate')
          .having((e) => e.httpStatus, 'httpStatus', 403)),
    );
  });

  test('chat defaults to a non-streaming JSON response (#23)', () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
          nodeId: 'self', name: 'self', dataDir: dir.path, apiPort: 0),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore([localModel('qwen3:0.6b')]),
      discovery: FakeDiscovery(),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();

    final response = await http.post(
      baseOf(service).resolve('/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': 'qwen3:0.6b',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }),
    );
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('application/json'));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final choice = (json['choices'] as List).single as Map;
    expect((choice['message'] as Map)['content'], 'Hello world');
  });

  test('pre-stream chat failures return an HTTP error, not 200 SSE (#23)',
      () async {
    final dir = Directory.systemTemp.createTempSync('llmmbc_api_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final service = LocalNodeService.internal(
      settings: NodeSettings(
          nodeId: 'self', name: 'self', dataDir: dir.path, apiPort: 0),
      hardwareProbe: FakeHardwareProbe(hw()),
      modelStore: FakeModelStore(),
      discovery: FakeDiscovery(),
      client: FakeNodeClient(),
      locator: FakeEngineLocator(),
      engine: FakeEngine(),
      planner: FakePlanner(),
      settingsPath: '${dir.path}/settings.json',
    );
    addTearDown(service.stop);
    await service.start();

    final response = await http.post(
      baseOf(service).resolve('/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': 'qwen3:0.6b',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'stream': true,
      }),
    );
    expect(response.statusCode, 403);
    expect(response.headers['content-type'], contains('application/json'));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    expect((json['error'] as Map)['code'], 'not_candidate');
  });
}
