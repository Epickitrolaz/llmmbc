// core-net: LAN discovery + peer directory (docs/ARCHITECTURE.md §4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../api/node_client.dart';
import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';

class _PeerEntry {
  NodeInfo info;
  DateTime lastSeen;
  bool reachable = true;
  bool manual;

  _PeerEntry(this.info, this.lastSeen, {this.manual = false});
}

/// UDP beacon/probe discovery with multicast, a /24 subnet sweep fallback and
/// manually configured peers.
class LanDiscovery implements Discovery {
  final NodeClient _client;
  final PlatformHooks _hooks;
  final DateTime Function() _now;

  /// Test/tuning seams.
  final bool sweepEnabled;
  final Duration sweepTimeout;
  final int sweepConcurrency;
  final Future<List<InternetAddress>> Function()? localAddresses;

  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _maintenanceTimer;
  NodeInfo Function()? _self;
  NodeSettings? _settings;
  bool _started = false;

  final Map<String, _PeerEntry> _peers = {};
  final Set<String> _resolving = {};
  final Set<String> _manualSpecs = {};
  final StreamController<List<NodeInfo>> _peersChanged =
      StreamController<List<NodeInfo>>.broadcast();
  List<InternetAddress> _interfaceAddresses = const [];
  String _lastEmittedKey = '';

  LanDiscovery({
    NodeClient? client,
    PlatformHooks hooks = const PlatformHooks(),
    DateTime Function()? now,
    this.sweepEnabled = true,
    this.sweepTimeout = const Duration(milliseconds: 300),
    this.sweepConcurrency = 64,
    this.localAddresses,
  })  : _client = client ?? HttpNodeClient(),
        _hooks = hooks,
        _now = now ?? DateTime.now;

  @override
  Future<void> start(NodeInfo Function() self, NodeSettings settings) async {
    _self = self;
    _settings = settings;
    _manualSpecs
      ..clear()
      ..addAll(settings.manualPeers);

    if (_started) {
      // Reconfiguration: refresh addresses and announce immediately.
      await _refreshInterfaces();
      _sendBeacon();
      await scan();
      return;
    }
    _started = true;

    try {
      await _hooks.multicastLock?.call(true);
    } catch (_) {
      // Optional platform hook; ignore failures.
    }

    await _refreshInterfaces();

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;
      try {
        socket.multicastLoopback = true;
      } catch (_) {
        // Loopback is best-effort; same-host nodes also use the sweep.
      }
      try {
        socket.joinMulticast(InternetAddress(kMulticastGroup));
      } catch (_) {
        // Multicast may be unavailable in some containers.
      }
      socket.listen(_onSocketEvent);
      _socket = socket;
    } catch (_) {
      // No permission / no interfaces: degrade to sweep + manual peers.
      _socket = null;
    }

    _beaconTimer = Timer.periodic(kBeaconInterval, (_) => _sendBeacon());
    _maintenanceTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _runMaintenance());

    _sendBeacon();
    _sendProbe();
    await scan();
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    try {
      _socket?.close();
    } catch (_) {
      // ignore
    }
    _socket = null;
    try {
      await _hooks.multicastLock?.call(false);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> scan() async {
    _sendProbe();
    for (final spec in _manualSpecs.toList()) {
      await addManualPeer(spec);
    }
    if (sweepEnabled) await _sweep();
  }

  @override
  List<NodeInfo> get peers {
    final list = [
      for (final e in _peers.values)
        if (e.info.nodeId != _selfId) _infoOf(e)
    ];
    list.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.nodeId.compareTo(b.nodeId);
    });
    return list;
  }

  @override
  Stream<List<NodeInfo>> get peersChanged => _peersChanged.stream;

  @override
  Future<NodeInfo?> addManualPeer(String hostPort) async {
    final spec = hostPort.trim();
    if (spec.isEmpty) return null;
    var host = spec;
    var port = _settings?.apiPort ?? kNodeApiPort;
    if (spec.contains('://')) {
      final uri = Uri.tryParse(spec);
      if (uri == null || uri.host.isEmpty) return null;
      host = uri.host;
      if (uri.hasPort) port = uri.port;
    } else {
      final colon = spec.lastIndexOf(':');
      if (colon > 0) {
        final parsed = int.tryParse(spec.substring(colon + 1));
        if (parsed != null) {
          host = spec.substring(0, colon);
          port = parsed;
        }
      }
    }
    if (host.isEmpty) return null;

    final info = await _fetch(Uri(scheme: 'http', host: host, port: port),
        const Duration(seconds: 2));
    if (info == null) return null;
    if (info.nodeId == _selfId) {
      return info.copyWith(
          host: host, reachable: true, isSelf: true, lastSeen: _now());
    }
    _manualSpecs.add(spec);
    _upsert(info, host: host, manual: true);
    return _peers[info.nodeId] == null ? null : _infoOf(_peers[info.nodeId]!);
  }

  // ---------------------------------------------------------------------------
  // Socket handling
  // ---------------------------------------------------------------------------

  String? get _selfId => _self?.call().nodeId;

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } on FormatException {
      return;
    }
    final type = message['t'];
    if (type == 'llmmbc.beacon') {
      _onBeacon(message, datagram.address);
    } else if (type == 'llmmbc.probe') {
      _replyBeacon(datagram.address, datagram.port);
    }
  }

  void _onBeacon(Map<String, dynamic> message, InternetAddress sender) {
    final id = message['id'];
    final port = message['port'];
    if (id is! String || port is! num) return;
    if (id == _selfId) return;

    final senderHost = sender.address;
    final entry = _peers[id];
    if (entry != null) {
      final changed = !entry.reachable || entry.info.apiPort != port.toInt();
      entry.lastSeen = _now();
      entry.reachable = true;
      if (entry.info.apiPort != port.toInt() || entry.info.host != senderHost) {
        _resolve(id, senderHost, port.toInt());
      } else if (changed) {
        _emitPeers();
      }
      return;
    }
    _resolve(id, senderHost, port.toInt());
  }

  void _resolve(String id, String host, int port) {
    if (!_resolving.add(id)) return;
    unawaited(() async {
      try {
        final info = await _fetch(Uri(scheme: 'http', host: host, port: port),
            const Duration(seconds: 2));
        if (info == null || info.nodeId != id) return;
        final manual = _peers[id]?.manual ?? false;
        _upsert(info, host: host, manual: manual);
      } finally {
        _resolving.remove(id);
      }
    }());
  }

  Future<NodeInfo?> _fetch(Uri base, Duration timeout) async {
    try {
      final NodeInfo info;
      final client = _client;
      if (client is HttpNodeClient) {
        info = await client.info(base, timeout: timeout);
      } else {
        info = await client.info(base).timeout(timeout);
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  void _upsert(NodeInfo info, {required String host, required bool manual}) {
    if (info.nodeId == _selfId) return;
    final previous = _peers[info.nodeId];
    final entry = previous ??
        _PeerEntry(
          info.copyWith(host: host, reachable: true, isSelf: false),
          _now(),
          manual: manual,
        );
    entry.info = info.copyWith(host: host, reachable: true, isSelf: false);
    entry.lastSeen = _now();
    entry.reachable = true;
    entry.manual = entry.manual || manual;
    _peers[info.nodeId] = entry;
    _emitPeers();
  }

  NodeInfo _infoOf(_PeerEntry e) => e.info
      .copyWith(reachable: e.reachable, isSelf: false, lastSeen: e.lastSeen);

  // ---------------------------------------------------------------------------
  // Beacons / probes
  // ---------------------------------------------------------------------------

  Future<void> _refreshInterfaces() async {
    try {
      final interfaces = await (localAddresses?.call() ?? _defaultAddresses());
      _interfaceAddresses =
          interfaces.where((a) => a.type == InternetAddressType.IPv4).toList();
    } catch (_) {
      _interfaceAddresses = const [];
    }
  }

  static Future<List<InternetAddress>> _defaultAddresses() async {
    final result = <InternetAddress>[];
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in interfaces) {
        result.addAll(iface.addresses);
      }
    } catch (_) {
      // no network information available
    }
    return result;
  }

  void _sendBeacon() {
    final self = _self?.call();
    final socket = _socket;
    if (self == null || socket == null) return;
    final payload = utf8.encode(jsonEncode({
      't': 'llmmbc.beacon',
      'v': kProtocolVersion,
      'id': self.nodeId,
      'name': self.name,
      'port': self.apiPort,
    }));
    _sendToNetwork(socket, payload);
  }

  void _sendProbe() {
    final self = _self?.call();
    final socket = _socket;
    if (self == null || socket == null) return;
    final payload = utf8.encode(jsonEncode({
      't': 'llmmbc.probe',
      'v': kProtocolVersion,
      'id': self.nodeId,
    }));
    _sendToNetwork(socket, payload);
  }

  void _replyBeacon(InternetAddress address, int port) {
    final self = _self?.call();
    final socket = _socket;
    if (self == null || socket == null) return;
    final payload = utf8.encode(jsonEncode({
      't': 'llmmbc.beacon',
      'v': kProtocolVersion,
      'id': self.nodeId,
      'name': self.name,
      'port': self.apiPort,
    }));
    try {
      socket.send(payload, address, port);
    } catch (_) {
      // best effort
    }
  }

  void _sendToNetwork(RawDatagramSocket socket, List<int> payload) {
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    for (final address in _interfaceAddresses) {
      if (address.isLoopback) continue;
      final parts = address.address.split('.');
      if (parts.length == 4) {
        targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
    }
    for (final target in targets) {
      try {
        socket.send(payload, target, kDiscoveryPort);
      } catch (_) {
        // interface without broadcast support
      }
    }
    try {
      socket.send(payload, InternetAddress(kMulticastGroup), kDiscoveryPort);
    } catch (_) {
      // multicast unavailable
    }
  }

  // ---------------------------------------------------------------------------
  // Maintenance / sweep
  // ---------------------------------------------------------------------------

  void _runMaintenance() {
    final now = _now();
    var changed = false;
    for (final id in _peers.keys.toList()) {
      final entry = _peers[id]!;
      if (entry.manual) continue;
      final age = now.difference(entry.lastSeen);
      if (age > kPeerDropAfter) {
        _peers.remove(id);
        changed = true;
      } else if (age > kPeerStaleAfter && entry.reachable) {
        entry.reachable = false;
        changed = true;
      }
    }
    if (changed) _emitPeers();
  }

  @visibleForTesting
  void debugSeedPeer(NodeInfo info, {bool manual = false, DateTime? lastSeen}) {
    _peers[info.nodeId] = _PeerEntry(info, lastSeen ?? _now(), manual: manual);
  }

  @visibleForTesting
  void debugRunMaintenance() => _runMaintenance();

  Future<void> _sweep() async {
    if (_interfaceAddresses.isEmpty) return;
    final targets = <String>{};
    final port = _settings?.apiPort ?? kNodeApiPort;
    for (final address in _interfaceAddresses) {
      if (address.isLoopback) continue;
      final parts = address.address.split('.');
      if (parts.length != 4) continue;
      // Cap to /24 even when the interface has a larger subnet.
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      for (var i = 1; i < 255; i++) {
        targets.add('$prefix.$i');
      }
    }

    final hosts = targets.toList();
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= hosts.length) return;
        final host = hosts[index];
        final info = await _fetch(
            Uri(scheme: 'http', host: host, port: port), sweepTimeout);
        if (info == null || info.nodeId == _selfId) continue;
        final manual = _peers[info.nodeId]?.manual ?? false;
        _upsert(info, host: host, manual: manual);
      }
    }

    final count = sweepConcurrency < 1
        ? 1
        : (sweepConcurrency > hosts.length ? hosts.length : sweepConcurrency);
    await Future.wait([for (var i = 0; i < count; i++) worker()]);
  }

  void _emitPeers() {
    final list = peers;
    final key = [for (final p in list) '${p.nodeId}:${p.reachable}'].join(',');
    if (key == _lastEmittedKey) return;
    _lastEmittedKey = key;
    if (!_peersChanged.isClosed) _peersChanged.add(list);
  }
}
