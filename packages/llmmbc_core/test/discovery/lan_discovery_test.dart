import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

import '../node/fakes.dart';

class FakeClock {
  DateTime now;
  FakeClock(this.now);
  void advance(Duration d) => now = now.add(d);
}

Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('two LanDiscovery instances on one host find each other', () async {
    final infoA = nodeInfo('a', name: 'node-a', apiPort: 48101);
    final infoB = nodeInfo('b', name: 'node-b', apiPort: 48102);
    final clientA = FakeNodeClient()..infoByPort[48102] = infoB;
    final clientB = FakeNodeClient()..infoByPort[48101] = infoA;

    final a = LanDiscovery(client: clientA, sweepEnabled: false);
    final b = LanDiscovery(client: clientB, sweepEnabled: false);
    addTearDown(a.stop);
    addTearDown(b.stop);

    await a.start(
      () => infoA,
      NodeSettings(
          nodeId: 'a', name: 'node-a', dataDir: '/tmp/a', apiPort: 48101),
    );
    final bChanges = <List<NodeInfo>>[];
    final sub = b.peersChanged.listen(bChanges.add);
    await b.start(
      () => infoB,
      NodeSettings(
          nodeId: 'b', name: 'node-b', dataDir: '/tmp/b', apiPort: 48102),
    );

    await waitFor(() =>
        a.peers.any((p) => p.nodeId == 'b') &&
        b.peers.any((p) => p.nodeId == 'a'));
    expect(a.peers.map((p) => p.nodeId), contains('b'));
    expect(b.peers.map((p) => p.nodeId), contains('a'));
    expect(a.peers.every((p) => !p.isSelf), isTrue);
    expect(bChanges, isNotEmpty);
    await sub.cancel();
  });

  test('sweep finds a node served by a local HttpServer', () async {
    final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    final address = interfaces
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.address.startsWith('169.254.'));
    final server = await HttpServer.bind(address, 0);
    final remote = nodeInfo('swept',
        name: 'swept', host: address.address, apiPort: server.port);
    server.listen((request) async {
      if (request.uri.path == '/v1/node') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(remote.toJson()));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final discovery = LanDiscovery(
      client: HttpNodeClient(timeout: const Duration(milliseconds: 300)),
      localAddresses: () async => [address],
    );
    addTearDown(discovery.stop);
    final settings = NodeSettings(
        nodeId: 'sweep-self',
        name: 'sweep-self',
        dataDir: '/tmp/s',
        apiPort: server.port);
    final self =
        nodeInfo('sweep-self', host: address.address, apiPort: server.port);

    await discovery.start(() => self, settings);
    await waitFor(() => discovery.peers.any((p) => p.nodeId == 'swept'),
        timeout: const Duration(seconds: 30));
    final peer = discovery.peers.firstWhere((p) => p.nodeId == 'swept');
    expect(peer.host, address.address);
    expect(peer.apiPort, server.port);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('scan is single-flight and keeps sweep concurrency bounded (#19)',
      () async {
    final client = FakeNodeClient();
    final discovery = LanDiscovery(
      client: client,
      localAddresses: () async => [InternetAddress('10.0.0.112')],
      sweepTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self', host: '10.0.0.112'),
      const NodeSettings(
          nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
    );
    expect(client.infoCalls, greaterThan(0));

    client.infoGate = Completer<void>();
    final first = discovery.scan();
    final second = discovery.scan();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.infoGate!.complete();
    await Future.wait([first, second]);
    expect(client.maxConcurrentInfoCalls, lessThanOrEqualTo(64));
  });

  test(
      'manual peers are remembered and retried after a failed first fetch (#20)',
      () async {
    final client = FakeNodeClient();
    final discovery = LanDiscovery(client: client, sweepEnabled: false);
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self'),
      const NodeSettings(
        nodeId: 'self',
        name: 'self',
        dataDir: '/tmp/d',
        apiPort: 47101,
        manualPeers: ['127.0.0.1:47101'],
      ),
    );
    expect(discovery.peers, isEmpty);

    client.infoByPort[47101] = nodeInfo('manual', apiPort: 47101);
    await discovery.scan();
    expect(discovery.peers.map((p) => p.nodeId), contains('manual'));
  });

  test('peersChanged fires on metadata-only changes (#21)', () async {
    final client = FakeNodeClient()
      ..infoByPort[47101] = nodeInfo('peer', apiPort: 47101);
    final discovery = LanDiscovery(client: client, sweepEnabled: false);
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self'),
      const NodeSettings(
        nodeId: 'self',
        name: 'self',
        dataDir: '/tmp/d',
        apiPort: 47101,
        manualPeers: ['127.0.0.1:47101'],
      ),
    );
    final events = <List<NodeInfo>>[];
    final sub = discovery.peersChanged.listen(events.add);

    client.infoByPort[47101] = nodeInfo(
      'peer',
      name: 'renamed',
      apiPort: 47101,
      models: [localModel('qwen3:0.6b')],
    );
    await discovery.addManualPeer('127.0.0.1:47101');
    await Future<void>.delayed(Duration.zero);

    expect(events, isNotEmpty);
    expect(events.last.single.name, 'renamed');
    expect(events.last.single.models.single.ref, ModelRef.parse('qwen3:0.6b'));
    await sub.cancel();
  });

  test('broadcast addresses use the interface netmask (#24)', () {
    expect(broadcastAddressFor('10.0.0.112', 24), '10.0.0.255');
    expect(broadcastAddressFor('172.20.5.7', 16), '172.20.255.255');
    expect(broadcastAddressFor('192.168.2.10', 23), '192.168.3.255');
  });

  test('discovery targets the netmask-derived broadcast (#24)', () async {
    final discovery = LanDiscovery(
      client: FakeNodeClient(),
      sweepEnabled: false,
      localAddresses: () async => [InternetAddress('172.20.5.7')],
      netmaskResolver: () async => {'172.20.5.7': 16},
    );
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self', host: '172.20.5.7'),
      const NodeSettings(
          nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
    );
    expect(discovery.debugBroadcastTargets(), contains('172.20.255.255'));
    expect(discovery.debugBroadcastTargets(), contains('255.255.255.255'));
  });

  test('stale peers become unreachable and are dropped; manual peers are kept',
      () async {
    final clock = FakeClock(DateTime(2025, 1, 1));
    final discovery = LanDiscovery(
      client: FakeNodeClient(),
      sweepEnabled: false,
      now: () => clock.now,
    );
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self'),
      const NodeSettings(
          nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
    );

    final changes = <List<NodeInfo>>[];
    final sub = discovery.peersChanged.listen(changes.add);
    discovery.debugSeedPeer(nodeInfo('auto', name: 'auto'),
        lastSeen: clock.now);
    discovery.debugSeedPeer(nodeInfo('manual', name: 'manual'),
        manual: true, lastSeen: clock.now);

    clock.advance(const Duration(seconds: 20));
    discovery.debugRunMaintenance();
    expect(discovery.peers.firstWhere((p) => p.nodeId == 'auto').reachable,
        isFalse);
    expect(discovery.peers.firstWhere((p) => p.nodeId == 'manual').reachable,
        isTrue);

    clock.advance(const Duration(seconds: 120));
    discovery.debugRunMaintenance();
    expect(discovery.peers.map((p) => p.nodeId), isNot(contains('auto')));
    expect(discovery.peers.map((p) => p.nodeId), contains('manual'));
    await Future<void>.delayed(Duration.zero);
    expect(changes, isNotEmpty);
    await sub.cancel();
  });

  test('addManualPeer resolves through GET /v1/node and is never dropped',
      () async {
    final clock = FakeClock(DateTime(2025, 1, 1));
    final remote = nodeInfo('manual-peer', name: 'manual-peer', apiPort: 47101);
    final client = FakeNodeClient()..infoByPort[47101] = remote;
    final discovery =
        LanDiscovery(client: client, sweepEnabled: false, now: () => clock.now);
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self'),
      const NodeSettings(
          nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
    );

    final resolved = await discovery.addManualPeer('127.0.0.1:47101');
    expect(resolved?.nodeId, 'manual-peer');
    expect(discovery.peers.map((p) => p.nodeId), contains('manual-peer'));

    clock.advance(const Duration(minutes: 5));
    discovery.debugRunMaintenance();
    expect(discovery.peers.map((p) => p.nodeId), contains('manual-peer'));
  });

  test('degrades gracefully when interface enumeration fails', () async {
    final remote = nodeInfo('still-there', apiPort: 47101);
    final client = FakeNodeClient()..infoByPort[47101] = remote;
    final discovery = LanDiscovery(
      client: client,
      sweepEnabled: false,
      localAddresses: () async => throw const SocketException('no interfaces'),
    );
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self'),
      const NodeSettings(
          nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
    );
    expect(discovery.peers, isEmpty);
    final resolved = await discovery.addManualPeer('127.0.0.1:47101');
    expect(resolved?.nodeId, 'still-there');
  });

  test('ignores its own node id', () async {
    final discovery =
        LanDiscovery(client: FakeNodeClient(), sweepEnabled: false);
    addTearDown(discovery.stop);
    await discovery.start(
      () => nodeInfo('self'),
      const NodeSettings(
          nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
    );
    discovery.debugSeedPeer(nodeInfo('self'));
    expect(discovery.peers.where((p) => p.nodeId == 'self'), isEmpty);
  });
}
