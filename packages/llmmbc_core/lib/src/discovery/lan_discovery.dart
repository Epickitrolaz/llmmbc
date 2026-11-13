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
  DateTime lastFetched;
  bool reachable = true;
  bool manual;

  _PeerEntry(this.info, this.lastSeen,
      {DateTime? lastFetched, this.manual = false})
      : lastFetched = lastFetched ?? lastSeen;
}

class _ScanToken {
  bool cancelled = false;
}

/// Computes the directed broadcast address for [address]/[prefixLength].
///
/// Exposed for tests; the default prefix resolution falls back to /24 when the
/// platform does not expose a netmask.
@visibleForTesting
String broadcastAddressFor(String address, int prefixLength) {
  final parts = address.split('.');
  if (parts.length != 4) return address;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return address;
    octets.add(value);
  }
  final ip =
      (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
  final prefix = prefixLength.clamp(0, 32);
  final mask = prefix == 0 ? 0 : ((0xffffffff << (32 - prefix)) & 0xffffffff);
  final broadcast = (ip & mask) | (~mask & 0xffffffff);
  return '${(broadcast >> 24) & 0xff}.${(broadcast >> 16) & 0xff}.'
      '${(broadcast >> 8) & 0xff}.${broadcast & 0xff}';
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
  final Future<Map<String, int>> Function()? netmaskResolver;

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
  Map<String, int> _prefixByAddress = const {};
  String _lastEmittedKey = '';

  /// Single-flight sweep so overlapping calls never exceed the concurrency
  /// budget and a cancelled stop does not leave work behind (#19).
  Future<void>? _scanFuture;
  _ScanToken? _scanToken;

  LanDiscovery({
    NodeClient? client,
    PlatformHooks hooks = const PlatformHooks(),
    DateTime Function()? now,
    this.sweepEnabled = true,
    this.sweepTimeout = const Duration(milliseconds: 300),
    this.sweepConcurrency = 64,
    this.localAddresses,
    this.netmaskResolver,
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
    _scanToken?.cancelled = true;
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
    final pending = _scanFuture;
    if (pending != null) {
      try {
        await pending.timeout(const Duration(seconds: 2));
      } on Object {
        // The sweep is cancelled at the next host and its HTTP calls time out.
      }
    }
    try {
      await _hooks.multicastLock?.call(false);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> scan() {
    final existing = _scanFuture;
    if (existing != null) return existing;
    final token = _ScanToken();
    _scanToken = token;
    final future = _runScan(token);
    late final Future<void> tracked;
    tracked = future.whenComplete(() {
      if (identical(_scanFuture, tracked)) {
        _scanFuture = null;
        _scanToken = null;
      }
    });
    _scanFuture = tracked;
    return tracked;
  }

  Future<void> _runScan(_ScanToken token) async {
    _sendProbe();
    if (token.cancelled) return;
    for (final spec in _manualSpecs.toList()) {
      if (token.cancelled) return;
      await addManualPeer(spec);
    }
    if (token.cancelled) return;
    if (sweepEnabled) await _sweep(token);
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

    // Remember the spec even when the peer is currently offline so later
    // scans retry it (#20).
    _manualSpecs.add(spec);

    final info = await _fetch(Uri(scheme: 'http', host: host, port: port),
        const Duration(seconds: 2));
    if (info == null) return null;
    if (info.nodeId == _selfId) {
      return info.copyWith(
          host: host, reachable: true, isSelf: true, lastSeen: _now());
    }
    _upsert(info, host: host, manual: true);
    return _peers[info.nodeId] == null ? null : _infoOf(_peers[info.nodeId]!);
  }

  /// Replaces the set of remembered manual peers (used by settings updates).
  void setManualPeers(Iterable<String> specs) {
    final wanted =
        [for (final s in specs) s.trim()].where((s) => s.isNotEmpty).toList();
    _manualSpecs
      ..clear()
      ..addAll(wanted);
    for (final id in _peers.keys.toList()) {
      final entry = _peers[id]!;
      if (!entry.manual) continue;
      final keep = wanted.any((spec) => _specMatches(spec, entry.info));
      if (!keep) _peers.remove(id);
    }
    _emitPeers();
  }

  static bool _specMatches(String spec, NodeInfo info) {
    if (spec.contains('://')) {
      final uri = Uri.tryParse(spec);
      if (uri == null) return false;
      return uri.host == info.host &&
          (!uri.hasPort || uri.port == info.apiPort);
    }
    final colon = spec.lastIndexOf(':');
    if (colon > 0) {
      final port = int.tryParse(spec.substring(colon + 1));
      if (port != null) {
        return spec.substring(0, colon) == info.host && port == info.apiPort;
      }
    }
    return spec == info.host;
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
    final now = _now();
    final entry = _peers[id];
    if (entry != null) {
      final wasReachable = entry.reachable;
      final changed = !wasReachable || entry.info.apiPort != port.toInt();
      entry.lastSeen = now;
      entry.reachable = true;
      // Refresh metadata periodically (models/worker/status can change) as well
      // as when the advertised endpoint moves (#21).
      final needsRefresh = entry.info.apiPort != port.toInt() ||
          entry.info.host != senderHost ||
          now.difference(entry.lastFetched) > const Duration(seconds: 15);
      if (needsRefresh) {
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
      final client = _client;
      if (client is HttpNodeClient) {
        // HttpNodeClient enforces the timeout (and aborts the connect phase at
        // the socket level), so a slow host cannot accumulate abandoned probes.
        return await client.info(base, timeout: timeout);
      }
      // Injected clients (tests) own their own completion semantics; awaiting
      // them keeps the <=64 in-flight bound exact.
      return await client.info(base);
    } catch (_) {
      return null;
    }
  }

  void _upsert(NodeInfo info, {required String host, required bool manual}) {
    if (info.nodeId == _selfId) return;
    final now = _now();
    final previous = _peers[info.nodeId];
    final entry = previous ??
        _PeerEntry(
          info.copyWith(host: host, reachable: true, isSelf: false),
          now,
          manual: manual,
        );
    entry.info = info.copyWith(host: host, reachable: true, isSelf: false);
    entry.lastSeen = now;
    entry.lastFetched = now;
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
    _prefixByAddress = await _resolvePrefixes();
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

  Future<Map<String, int>> _resolvePrefixes() async {
    final custom = netmaskResolver;
    if (custom != null) {
      try {
        return await custom();
      } on Object {
        return const {};
      }
    }
    if (!Platform.isLinux && !Platform.isAndroid) return const {};
    try {
      final lines = await File('/proc/net/route').readAsLines();
      final routes = <({int network, int mask, int prefix})>[];
      for (final line in lines.skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 8) continue;
        final network = _littleEndianHex(fields[1]);
        final mask = _littleEndianHex(fields[7]);
        final prefix = _prefixLength(mask);
        if (prefix > 0) {
          routes.add((network: network, mask: mask, prefix: prefix));
        }
      }
      final result = <String, int>{};
      for (final address in _interfaceAddresses) {
        final ip = _ipv4ToInt(address.address);
        if (ip == null) continue;
        var best = 0;
        for (final route in routes) {
          if ((ip & route.mask) == route.network && route.prefix > best) {
            best = route.prefix;
          }
        }
        if (best > 0) result[address.address] = best;
      }
      return result;
    } on Object {
      return const {};
    }
  }

  static int _littleEndianHex(String hex) {
    final value = int.tryParse(hex, radix: 16) ?? 0;
    return ((value & 0xff) << 24) |
        ((value & 0xff00) << 8) |
        ((value >> 8) & 0xff00) |
        ((value >> 24) & 0xff);
  }

  static int _prefixLength(int mask) {
    var prefix = 0;
    for (var bit = 31; bit >= 0; bit--) {
      if ((mask >> bit) & 1 == 1) {
        prefix++;
      } else {
        break;
      }
    }
    return prefix;
  }

  static int? _ipv4ToInt(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      value = (value << 8) | octet;
    }
    return value;
  }

  List<String> _broadcastTargets() {
    final targets = <String>{'255.255.255.255'};
    for (final address in _interfaceAddresses) {
      if (address.isLoopback) continue;
      final prefix = _prefixByAddress[address.address] ?? 24;
      targets.add(broadcastAddressFor(address.address, prefix));
    }
    return targets.toList(growable: false);
  }

  @visibleForTesting
  List<String> debugBroadcastTargets() => _broadcastTargets();

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
    for (final target in _broadcastTargets()) {
      try {
        socket.send(payload, InternetAddress(target), kDiscoveryPort);
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

  Future<void> _sweep(_ScanToken token) async {
    if (_interfaceAddresses.isEmpty) return;
    final targets = <String>{};
    final port = _self?.call().apiPort ?? _settings?.apiPort ?? kNodeApiPort;
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
      while (!token.cancelled) {
        final index = next++;
        if (index >= hosts.length) return;
        final host = hosts[index];
        final info = await _fetch(
            Uri(scheme: 'http', host: host, port: port), sweepTimeout);
        if (token.cancelled) return;
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
    // Include every wire-visible field so metadata-only updates (models, name,
    // status, worker flag, hardware) also notify listeners (#21).
    final key = [
      for (final p in list) '${p.reachable}:${jsonEncode(p.toJson())}'
    ].join('|');
    if (key == _lastEmittedKey) return;
    _lastEmittedKey = key;
    if (!_peersChanged.isClosed) _peersChanged.add(list);
  }
}
