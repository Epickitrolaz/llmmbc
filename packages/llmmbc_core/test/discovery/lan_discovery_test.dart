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

/// Number of socket FDs held by this isolate's process (Linux only).
int socketFdCount() {
  var count = 0;
  for (final entity in Directory('/proc/self/fd').listSync()) {
    try {
      if (Link(entity.path).targetSync().startsWith('socket:')) count++;
    } on FileSystemException {
      // FD closed while listing.
    }
  }
  return count;
}

/// ESTABLISHED TCP connections involving [port] (Linux only).
int establishedForPort(int port) {
  final file = File('/proc/net/tcp');
  if (!file.existsSync()) return 0;
  var count = 0;
  for (final line in file.readAsLinesSync().skip(1)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 4 || fields[3] != '01') continue; // 01 = ESTABLISHED
    final localPort = int.parse(fields[1].split(':').last, radix: 16);
    final remotePort = int.parse(fields[2].split(':').last, radix: 16);
    if (localPort == port || remotePort == port) count++;
  }
  return count;
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

  test('beacons advertise the memory budget (§2.5)', () async {
    final info = nodeInfo('a', apiPort: 48111, memoryBudgetBytes: 7 << 30);
    final discovery =
        LanDiscovery(client: FakeNodeClient(), sweepEnabled: false);
    addTearDown(discovery.stop);
    await discovery.start(
      () => info,
      NodeSettings(nodeId: 'a', name: 'a', dataDir: '/tmp/a', apiPort: 48111),
    );
    final beacon = discovery.debugBeaconPayload();
    expect(beacon['t'], 'llmmbc.beacon');
    expect(beacon['id'], 'a');
    expect(beacon['port'], 48111);
    expect(beacon['memoryBudgetBytes'], 7 << 30);
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

  group('HTTP liveness (§4)', () {
    Future<LanDiscovery> startedLiveness(
      FakeClock clock,
      FakeNodeClient client, {
      int probeConcurrency = 8,
    }) async {
      final discovery = LanDiscovery(
        client: client,
        sweepEnabled: false,
        now: () => clock.now,
        probeConcurrency: probeConcurrency,
      );
      addTearDown(discovery.stop);
      await discovery.start(
        () => nodeInfo('self'),
        const NodeSettings(
            nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
      );
      return discovery;
    }

    test('quiet peers that answer GET /v1/node stay reachable for 10 minutes',
        () async {
      final clock = FakeClock(DateTime(2025, 1, 1));
      final client = FakeNodeClient()
        ..infoByPort[47101] = nodeInfo('remote', name: 'remote', apiPort: 47101);
      final discovery = await startedLiveness(clock, client);
      discovery.debugSeedPeer(
          nodeInfo('remote', name: 'remote', apiPort: 47101),
          lastSeen: clock.now);

      // No beacons at all: only the HTTP probes keep this peer alive.
      final probesAtStart = client.infoCalls;
      for (var i = 0; i < 120; i++) {
        clock.advance(const Duration(seconds: 5));
        await discovery.debugRunMaintenanceAsync();
        final peer =
            discovery.peers.singleWhere((p) => p.nodeId == 'remote');
        expect(peer.reachable, isTrue,
            reason: 'peer went offline after ${(i + 1) * 5}s without UDP');
      }
      expect(client.infoCalls - probesAtStart, greaterThan(60));
    });

    test('3 failed probes mark it unreachable; a success restores it at once',
        () async {
      final clock = FakeClock(DateTime(2025, 1, 1));
      final remote = nodeInfo('remote', name: 'remote', apiPort: 47101);
      final client = FakeNodeClient()..infoByPort[47101] = remote;
      final discovery = await startedLiveness(clock, client);
      discovery.debugSeedPeer(remote, lastSeen: clock.now);

      clock.advance(const Duration(seconds: 5));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.single.reachable, isTrue);

      // The node stops answering: the next three probes fail.
      client.infoByPort.remove(47101);
      clock.advance(const Duration(seconds: 5));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.single.reachable, isTrue,
          reason: 'one failure must not flap the peer');
      clock.advance(const Duration(seconds: 5));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.single.reachable, isTrue,
          reason: 'two failures must not flap the peer');

      clock.advance(const Duration(seconds: 5));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.single.reachable, isFalse,
          reason: 'unreachable after three consecutive failures (~15 s)');

      // It answers again: reachable immediately, metadata refreshed.
      client.infoByPort[47101] =
          nodeInfo('remote', name: 'remote-renamed', apiPort: 47101);
      clock.advance(const Duration(seconds: 5));
      await discovery.debugRunMaintenanceAsync();
      final back = discovery.peers.single;
      expect(back.reachable, isTrue);
      expect(back.name, 'remote-renamed');
    });

    test('drops an unreachable auto peer after 120 s but keeps manual peers',
        () async {
      final clock = FakeClock(DateTime(2025, 1, 1));
      // Neither peer answers HTTP.
      final discovery = await startedLiveness(clock, FakeNodeClient());
      discovery.debugSeedPeer(nodeInfo('auto', name: 'auto'),
          lastSeen: clock.now);
      discovery.debugSeedPeer(nodeInfo('manual', name: 'manual'),
          manual: true, lastSeen: clock.now);

      final changes = <List<NodeInfo>>[];
      final sub = discovery.peersChanged.listen(changes.add);

      for (var i = 0; i < 3; i++) {
        clock.advance(const Duration(seconds: 5));
        await discovery.debugRunMaintenanceAsync();
      }
      expect(discovery.peers.firstWhere((p) => p.nodeId == 'auto').reachable,
          isFalse);
      expect(discovery.peers.firstWhere((p) => p.nodeId == 'manual').reachable,
          isFalse);

      // 15 s (unreachable) + 106 s = 121 s since the last contact.
      clock.advance(const Duration(seconds: 106));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.map((p) => p.nodeId), isNot(contains('auto')));

      clock.advance(const Duration(minutes: 5));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.map((p) => p.nodeId), contains('manual'));
      await Future<void>.delayed(Duration.zero);
      expect(changes, isNotEmpty);
      await sub.cancel();
    });

    test('probes never overlap and stay within the concurrency bound', () async {
      final clock = FakeClock(DateTime(2025, 1, 1));
      final client = FakeNodeClient()..infoGate = Completer<void>();
      for (var i = 0; i < 10; i++) {
        client.infoByPort[47200 + i] =
            nodeInfo('peer$i', apiPort: 47200 + i);
      }
      final discovery =
          await startedLiveness(clock, client, probeConcurrency: 4);
      for (var i = 0; i < 10; i++) {
        discovery.debugSeedPeer(nodeInfo('peer$i', apiPort: 47200 + i),
            lastSeen: clock.now);
      }

      clock.advance(const Duration(seconds: 5));
      discovery.debugRunMaintenance();
      expect(client.maxConcurrentInfoCalls, 4,
          reason: 'bounded concurrency, one probe per peer');

      // A second pass while probes are in flight must not add duplicates.
      clock.advance(const Duration(seconds: 5));
      discovery.debugRunMaintenance();
      expect(client.concurrentInfoCalls, 4);
      expect(client.maxConcurrentInfoCalls, 4);

      client.infoGate!.complete();
      await discovery.debugWaitForProbes();
      expect(discovery.peers, hasLength(10));
      expect(discovery.peers.every((p) => p.reachable), isTrue);
    });

    test('a timed-out probe aborts its socket: no FD or ESTABLISHED growth (#75)',
        () async {
      if (!Platform.isLinux) {
        markTestSkipped('FD/socket introspection needs /proc (Linux)');
        return;
      }
      // A listening socket that never accepts: the kernel completes the TCP
      // handshake, the process never answers GET /v1/node (a stalled peer).
      final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, 0,
          backlog: 128);
      addTearDown(() => server.close());

      final clock = FakeClock(DateTime(2025, 1, 1));
      final discovery = LanDiscovery(
        client: HttpNodeClient(timeout: const Duration(milliseconds: 250)),
        sweepEnabled: false,
        now: () => clock.now,
        probeTimeout: const Duration(milliseconds: 250),
      );
      addTearDown(discovery.stop);
      await discovery.start(
        () => nodeInfo('self'),
        const NodeSettings(
            nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
      );
      discovery.debugSeedPeer(
          nodeInfo('stalled', host: '127.0.0.1', apiPort: server.port),
          lastSeen: clock.now);

      Future<void> cycle() async {
        clock.advance(const Duration(seconds: 5));
        await discovery.debugRunMaintenanceAsync();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      // Baseline after one timed-out probe so transient startup FDs settle.
      await cycle();
      final baselineFds = socketFdCount();
      for (var i = 0; i < 8; i++) {
        await cycle();
      }
      expect(discovery.peers.single.reachable, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(socketFdCount() - baselineFds, lessThanOrEqualTo(2),
          reason: 'every timed-out probe must close its own socket (#75)');
      expect(establishedForPort(server.port), 0,
          reason: 'no ESTABLISHED liveness connection may be left behind');
    });

    test('maintenance retries an unresolved manual peer without scan() (#76)',
        () async {
      final clock = FakeClock(DateTime(2025, 1, 1));
      final client = FakeNodeClient(); // the manual peer is not up yet
      final discovery = LanDiscovery(
        client: client,
        sweepEnabled: false,
        now: () => clock.now,
      );
      addTearDown(discovery.stop);
      await discovery.start(
        () => nodeInfo('self'),
        const NodeSettings(
            nodeId: 'self',
            name: 'self',
            dataDir: '/tmp/d',
            apiPort: 47101,
            manualPeers: ['127.0.0.1:49999']),
      );
      expect(discovery.peers, isEmpty);
      final callsAfterStartup = client.infoCalls;

      // The backoff prevents a second attempt on the next maintenance tick.
      clock.advance(const Duration(seconds: 1));
      await discovery.debugRunMaintenanceAsync();
      expect(client.infoCalls, callsAfterStartup);

      // The peer starts later; only the maintenance loop may find it.
      client.infoByPort[49999] =
          nodeInfo('late', name: 'late', apiPort: 49999);
      clock.advance(const Duration(seconds: 15));
      await discovery.debugRunMaintenanceAsync();
      expect(discovery.peers.map((p) => p.nodeId), contains('late'));
    });
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

  group('no default route (#40)', () {
    test('validates broadcast targets', () {
      expect(isUsableBroadcastAddress('10.0.0.255'), isTrue);
      expect(isUsableBroadcastAddress('172.20.255.255'), isTrue);
      expect(isUsableBroadcastAddress('0.0.0.0'), isFalse);
      expect(isUsableBroadcastAddress('0.0.0.255'), isFalse);
      expect(isUsableBroadcastAddress('127.0.0.1'), isFalse);
      expect(isUsableBroadcastAddress('10.0.0.256'), isFalse);
      expect(isUsableBroadcastAddress('not-an-ip'), isFalse);
    });

    test('never sends to 0.0.0.0 or an unspecified broadcast', () async {
      final discovery = LanDiscovery(
        client: FakeNodeClient(),
        sweepEnabled: false,
        localAddresses: () async => [InternetAddress('0.0.0.0')],
        netmaskResolver: () async => {'0.0.0.0': 24},
        defaultRouteResolver: () async => true,
      );
      addTearDown(discovery.stop);
      await discovery.start(
        () => nodeInfo('self', host: '0.0.0.0'),
        const NodeSettings(
            nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
      );
      final targets = discovery.debugBroadcastTargets();
      expect(targets, isNot(contains('0.0.0.0')));
      expect(targets, isNot(contains('0.0.0.255')));
    });

    test('skips the limited broadcast but keeps the subnet broadcast',
        () async {
      final discovery = LanDiscovery(
        client: FakeNodeClient(),
        sweepEnabled: false,
        localAddresses: () async => [InternetAddress('10.99.0.1')],
        netmaskResolver: () async => {'10.99.0.1': 24},
        defaultRouteResolver: () async => false,
      );
      addTearDown(discovery.stop);
      await discovery.start(
        () => nodeInfo('self', host: '10.99.0.1'),
        const NodeSettings(
            nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
      );
      expect(discovery.debugHasDefaultRoute, isFalse);
      expect(discovery.debugBroadcastTargets(), ['10.99.0.255']);
    });

    test('starts without interfaces and keeps manual peers working', () async {
      final remote = nodeInfo('manual-peer', apiPort: 47101);
      final client = FakeNodeClient()..infoByPort[47101] = remote;
      final discovery = LanDiscovery(
        client: client,
        sweepEnabled: false,
        localAddresses: () async => const [],
        defaultRouteResolver: () async => false,
      );
      addTearDown(discovery.stop);
      await discovery.start(
        () => nodeInfo('self'),
        const NodeSettings(
            nodeId: 'self', name: 'self', dataDir: '/tmp/d', apiPort: 47101),
      );
      expect(discovery.debugBroadcastTargets(), isEmpty);
      final resolved = await discovery.addManualPeer('127.0.0.1:47101');
      expect(resolved?.nodeId, 'manual-peer');
      expect(discovery.peers.map((p) => p.nodeId), contains('manual-peer'));
    });
  });

  group('peer identity (#49)', () {
    test('an endpoint re-resolving to a new nodeId replaces the old peer',
        () async {
      final client = FakeNodeClient()
        ..infoByPort[47101] =
            nodeInfo('old-id', host: '127.0.0.1', apiPort: 47101);
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
      expect(discovery.peers.map((p) => p.nodeId), ['old-id']);

      // The node restarted/reinstalled at the same address with a fresh id.
      client.infoByPort[47101] =
          nodeInfo('new-id', host: '127.0.0.1', apiPort: 47101);
      await discovery.addManualPeer('127.0.0.1:47101');

      expect(discovery.peers.map((p) => p.nodeId), ['new-id']);
      expect(discovery.peers.single.apiPort, 47101);
    });

    test('replacing a manual peer by a new identity keeps manual semantics',
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

      discovery.debugSeedPeer(
        nodeInfo('old-id', host: '127.0.0.1', apiPort: 47102),
        manual: true,
        lastSeen: clock.now,
      );
      // A beacon/sweep now resolves the same endpoint to a fresh identity.
      discovery.debugUpsert(
        nodeInfo('new-id', host: '127.0.0.1', apiPort: 47102),
        host: '127.0.0.1',
      );

      expect(discovery.peers.map((p) => p.nodeId), ['new-id']);
      // Manual peers are never dropped by maintenance; the replacement
      // inherits that flag from the stale entry.
      clock.advance(const Duration(minutes: 5));
      discovery.debugRunMaintenance();
      expect(discovery.peers.map((p) => p.nodeId), ['new-id']);
    });
  });
}
