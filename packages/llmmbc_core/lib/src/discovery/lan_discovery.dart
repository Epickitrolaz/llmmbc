// core-net: LAN discovery + peer directory (docs/ARCHITECTURE.md §4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../api/node_client.dart';
import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';

/// How often a peer that has gone quiet is checked over HTTP (§4).
const Duration kPeerProbeInterval = Duration(seconds: 5);

/// `GET /v1/node` timeout for a liveness probe (§4).
const Duration kPeerProbeTimeout = Duration(seconds: 2);

/// Consecutive failed probes before a peer is shown as unreachable (§4).
const int kPeerProbeFailures = 3;

/// How often an unresolved/unreachable manual peer spec is retried (#76).
const Duration kManualPeerRetryInterval = Duration(seconds: 15);

class _ManualRetry {
  DateTime? lastAttempt;
  bool inFlight = false;
}

class _PeerEntry {
  NodeInfo info;
  DateTime lastSeen;
  DateTime lastFetched;
  DateTime lastProbed;
  bool reachable = true;
  bool manual;

  /// Consecutive failed HTTP liveness probes; reset by a beacon, a successful
  /// probe or any other `/v1/node` fetch.
  int failures = 0;

  /// True while this peer has a probe in flight, so probes never overlap.
  bool probing = false;

  _PeerEntry(this.info, this.lastSeen,
      {DateTime? lastFetched, DateTime? lastProbed, this.manual = false})
      : lastFetched = lastFetched ?? lastSeen,
        lastProbed = lastProbed ?? lastSeen;
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

/// Whether [address] can be used as a UDP broadcast destination.
///
/// Rejects malformed input, `0.0.0.0` (and other `0.x.x.x` unspecified forms)
/// and loopback targets, which the kernel reports as unreachable (#40).
@visibleForTesting
bool isUsableBroadcastAddress(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
  }
  final first = int.parse(parts.first);
  return first != 0 && first != 127;
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
  final Duration probeInterval;
  final Duration probeTimeout;
  final int probeFailures;
  final int probeConcurrency;
  final Duration manualRetryInterval;
  final Future<List<InternetAddress>> Function()? localAddresses;
  final Future<Map<String, int>> Function()? netmaskResolver;

  /// Test seam for the default-route probe (Linux/Android use /proc/net/route).
  final Future<bool> Function()? defaultRouteResolver;

  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _maintenanceTimer;
  NodeInfo Function()? _self;
  NodeSettings? _settings;
  bool _started = false;
  bool _hasDefaultRoute = true;
  bool _reportedSendError = false;

  final Map<String, _PeerEntry> _peers = {};
  final Set<String> _resolving = {};
  final Set<String> _manualSpecs = {};
  final Map<String, _ManualRetry> _manualRetries = {};
  final StreamController<List<NodeInfo>> _peersChanged =
      StreamController<List<NodeInfo>>.broadcast();
  List<InternetAddress> _interfaceAddresses = const [];
  Map<String, int> _prefixByAddress = const {};
  String _lastEmittedKey = '';

  /// Single-flight sweep so overlapping calls never exceed the concurrency
  /// budget and a cancelled stop does not leave work behind (#19).
  Future<void>? _scanFuture;
  _ScanToken? _scanToken;
  HttpNodeClient? _sweepClient;

  /// Peers whose HTTP liveness probe is in flight; never probed twice at once.
  int _activeProbes = 0;
  final Set<Future<void>> _inFlightProbes = {};

  /// Maintenance retries of unresolved/unreachable manual peer specs (#76).
  final Set<Future<void>> _inFlightManualRetries = {};

  /// Per-probe clients, force-closed on [stop] so an in-flight probe against a
  /// stalled peer never outlives discovery (#75).
  final Set<HttpClient> _activeProbeClients = {};

  LanDiscovery({
    NodeClient? client,
    PlatformHooks hooks = const PlatformHooks(),
    DateTime Function()? now,
    this.sweepEnabled = true,
    this.sweepTimeout = const Duration(milliseconds: 300),
    this.sweepConcurrency = 64,
    this.probeInterval = kPeerProbeInterval,
    this.probeTimeout = kPeerProbeTimeout,
    this.probeFailures = kPeerProbeFailures,
    this.probeConcurrency = 8,
    this.manualRetryInterval = kManualPeerRetryInterval,
    this.localAddresses,
    this.netmaskResolver,
    this.defaultRouteResolver,
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
      socket.listen(_onSocketEvent,
          onError: _onSocketError, cancelOnError: false);
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
    _sweepClient?.close();
    _sweepClient = null;
    for (final client in _activeProbeClients.toList()) {
      try {
        client.close(force: true);
      } catch (_) {
        // Already closed.
      }
    }
    _activeProbeClients.clear();
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

    // Remember the spec even when the peer is currently offline so the
    // maintenance loop can retry it without a manual scan (#20, #76).
    _manualSpecs.add(spec);
    // Anchor the retry backoff to this attempt, whichever caller made it.
    _manualRetries.putIfAbsent(spec, _ManualRetry.new).lastAttempt = _now();

    final info = await _fetchInfo(
        Uri(scheme: 'http', host: host, port: port),
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
    _manualRetries.removeWhere((spec, _) => !wanted.contains(spec));
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
      // A beacon proves liveness exactly like a successful probe (§4).
      entry.failures = 0;
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
        final info = await _fetchInfo(
            Uri(scheme: 'http', host: host, port: port),
            const Duration(seconds: 2));
        if (info == null || info.nodeId != id) return;
        final manual = _peers[id]?.manual ?? false;
        _upsert(info, host: host, manual: manual);
      } finally {
        _resolving.remove(id);
      }
    }());
  }

  Future<NodeInfo?> _fetch(Uri base, Duration timeout,
      {NodeClient? client}) async {
    try {
      final effective = client ?? _client;
      if (effective is HttpNodeClient) {
        // HttpNodeClient enforces the timeout (and its HttpClient connection
        // timeout aborts unreachable hosts at the socket level), so an
        // abandoned probe cannot keep counting against the concurrency bound.
        return await effective.info(base, timeout: timeout);
      }
      // Injected clients (tests) own their own completion semantics; awaiting
      // them keeps the <=64 in-flight bound exact.
      return await effective.info(base);
    } catch (_) {
      return null;
    }
  }

  void _upsert(NodeInfo info, {required String host, required bool manual}) {
    if (info.nodeId == _selfId) return;
    final now = _now();

    // A node that restarts or is reinstalled keeps its endpoint but reports a
    // new nodeId. An endpoint has exactly one listener, so replace the stale
    // identity instead of keeping both (#49). A manual peer stays manual across
    // the identity change, otherwise maintenance would drop it later.
    var effectiveManual = manual;
    for (final id in _peers.keys.toList()) {
      if (id == info.nodeId) continue;
      final existing = _peers[id]!;
      if (existing.info.host == host && existing.info.apiPort == info.apiPort) {
        effectiveManual = effectiveManual || existing.manual;
        _peers.remove(id);
      }
    }

    final previous = _peers[info.nodeId];
    final entry = previous ??
        _PeerEntry(
          info.copyWith(host: host, reachable: true, isSelf: false),
          now,
          manual: effectiveManual,
        );
    entry.info = info.copyWith(host: host, reachable: true, isSelf: false);
    entry.lastSeen = now;
    entry.lastFetched = now;
    entry.lastProbed = now;
    entry.reachable = true;
    entry.failures = 0;
    entry.manual = entry.manual || effectiveManual;
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
    _hasDefaultRoute = await _resolveHasDefaultRoute();
  }

  /// A host without a default route (airplane mode, netns, some lab/Android
  /// setups) cannot send to 255.255.255.255: skip it instead of crashing (#40).
  Future<bool> _resolveHasDefaultRoute() async {
    final custom = defaultRouteResolver;
    if (custom != null) {
      try {
        return await custom();
      } on Object {
        return true;
      }
    }
    if (!Platform.isLinux && !Platform.isAndroid) return true;
    try {
      final lines = await File('/proc/net/route').readAsLines();
      for (final line in lines.skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 8) continue;
        if (fields[1] == '00000000' && fields[7] == '00000000') return true;
      }
      return false;
    } on Object {
      return true;
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
    final targets = <String>{};
    // The limited broadcast needs a default route; without one the kernel
    // reports ENETUNREACH and an unhandled socket error used to kill the node.
    if (_hasDefaultRoute) targets.add('255.255.255.255');
    for (final address in _interfaceAddresses) {
      if (address.isLoopback) continue;
      if (!isUsableBroadcastAddress(address.address)) continue;
      final prefix = _prefixByAddress[address.address] ?? 24;
      final broadcast = broadcastAddressFor(address.address, prefix);
      if (!isUsableBroadcastAddress(broadcast)) continue;
      if (broadcast == '255.255.255.255' && !_hasDefaultRoute) continue;
      targets.add(broadcast);
    }
    return targets.toList(growable: false);
  }

  @visibleForTesting
  List<String> debugBroadcastTargets() => _broadcastTargets();

  @visibleForTesting
  Map<String, dynamic> debugBeaconPayload() {
    final self = _self?.call();
    if (self == null) throw StateError('discovery not started');
    return _beaconPayload(self);
  }

  @visibleForTesting
  bool get debugHasDefaultRoute => _hasDefaultRoute;

  void _onSocketError(Object error) {
    // RawDatagramSocket reports send failures asynchronously on its stream;
    // without this handler they become unhandled errors and abort the process.
    _logSendFailure(error);
  }

  void _logSendFailure(Object error) {
    if (_reportedSendError) return;
    _reportedSendError = true;
    try {
      stderr.writeln('llmmbc discovery: UDP send failed ($error); '
          'continuing with the subnet sweep and manual peers');
    } on Object {
      // Logging must never fail startup.
    }
  }

  Map<String, dynamic> _beaconPayload(NodeInfo self) => {
        't': 'llmmbc.beacon',
        'v': kProtocolVersion,
        'id': self.nodeId,
        'name': self.name,
        'port': self.apiPort,
        // Advertised budget (§2.5); additive, older peers ignore it and fall
        // back to `GET /v1/node`.
        'memoryBudgetBytes': self.memoryBudgetBytes,
      };

  void _sendBeacon() {
    final self = _self?.call();
    final socket = _socket;
    if (self == null || socket == null) return;
    final payload = utf8.encode(jsonEncode(_beaconPayload(self)));
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
    final payload = utf8.encode(jsonEncode(_beaconPayload(self)));
    try {
      socket.send(payload, address, port);
    } catch (_) {
      // best effort
    }
  }

  void _sendToNetwork(RawDatagramSocket socket, List<int> payload) {
    for (final target in _broadcastTargets()) {
      final address = InternetAddress.tryParse(target);
      if (address == null || address.address == '0.0.0.0') continue;
      try {
        socket.send(payload, address, kDiscoveryPort);
      } catch (e) {
        _logSendFailure(e);
      }
    }
    try {
      socket.send(payload, InternetAddress(kMulticastGroup), kDiscoveryPort);
    } catch (e) {
      _logSendFailure(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Maintenance / sweep
  // ---------------------------------------------------------------------------

  /// Liveness + expiry pass (§4).
  ///
  /// UDP is not reliable on Wi-Fi/Android, so peers are also probed over HTTP:
  /// every known peer not heard from (beacon or HTTP) in [probeInterval] is
  /// probed with `GET /v1/node` ([probeTimeout]) at most once per
  /// [probeInterval]. [probeFailures] consecutive failures mark it unreachable;
  /// [kPeerDropAfter] without any contact drops it (manual peers are kept).
  /// A successful probe or beacon makes it reachable again immediately.
  void _runMaintenance() {
    final now = _now();
    var changed = false;
    for (final id in _peers.keys.toList()) {
      final entry = _peers[id]!;
      if (!entry.manual && now.difference(entry.lastSeen) > kPeerDropAfter) {
        _peers.remove(id);
        changed = true;
      }
    }
    if (changed) _emitPeers();

    _probeQuietPeers(now);
    _retryManualPeers(now);
  }

  /// Retries manual peer specs that have no entry yet or whose entry is
  /// currently unreachable (#76). Without this, a peer that starts after this
  /// node's startup scan is never discovered on a network that drops UDP until
  /// the user presses Rescan.
  void _retryManualPeers(DateTime now) {
    if (_manualSpecs.isEmpty) return;
    final entries = _peers.values.toList();
    for (final spec in _manualSpecs.toList()) {
      final matching =
          entries.where((entry) => _specMatches(spec, entry.info)).toList();
      if (matching.any((entry) => entry.reachable)) {
        _manualRetries.remove(spec);
        continue;
      }
      // A probe already in flight is the retry; do not stack a second request.
      if (matching.any((entry) => entry.probing)) continue;
      final state = _manualRetries.putIfAbsent(spec, _ManualRetry.new);
      if (state.inFlight) continue;
      final last = state.lastAttempt;
      if (last != null && now.difference(last) < manualRetryInterval) continue;
      state.lastAttempt = now;
      state.inFlight = true;
      late final Future<void> tracked;
      tracked = addManualPeer(spec)
          .then<void>((_) {})
          .catchError((Object _) {})
          .whenComplete(() {
        state.inFlight = false;
        _inFlightManualRetries.remove(tracked);
      });
      _inFlightManualRetries.add(tracked);
    }
  }

  void _probeQuietPeers(DateTime now) {
    for (final entry in _peers.values.toList()) {
      if (entry.probing) continue;
      if (now.difference(entry.lastSeen) < probeInterval) continue;
      // Never probe more often than the liveness interval, even while a peer
      // stays quiet and its probes keep failing.
      if (now.difference(entry.lastProbed) < probeInterval) continue;
      if (_activeProbes >= probeConcurrency) return;
      _startProbe(entry);
    }
  }

  void _startProbe(_PeerEntry entry) {
    entry.probing = true;
    entry.lastProbed = _now();
    _activeProbes++;
    late final Future<void> tracked;
    tracked = _probe(entry).whenComplete(() {
      entry.probing = false;
      _activeProbes--;
      _inFlightProbes.remove(tracked);
    });
    _inFlightProbes.add(tracked);
  }

  /// One liveness probe with its own [HttpClient].
  ///
  /// `package:http`'s `Future.timeout` only abandons the caller's future: the
  /// socket stays ESTABLISHED until the peer answers (or the OS gives up), which
  /// leaks one FD per probe against a stalled peer (#75). Here a hard timer
  /// force-closes this probe's client, which aborts the request and releases
  /// the socket immediately. `maxConnectionsPerHost = 1` plus the per-peer
  /// single-flight flag bounds each peer to one probe connection.
  Future<NodeInfo?> _httpProbe(Uri base, {Duration? timeout}) async {
    final limit = timeout ?? probeTimeout;
    final client = HttpClient()
      ..connectionTimeout = limit
      ..maxConnectionsPerHost = 1;
    _activeProbeClients.add(client);
    final deadline = Timer(limit, () => client.close(force: true));
    try {
      final request = await client.getUrl(base.resolve('/v1/node'));
      request.headers.set(kHeaderProtocol, '$kProtocolVersion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decoder.bind(response).join();
      final info =
          NodeInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
      return info.host.isEmpty ? info.copyWith(host: base.host) : info;
    } on Object {
      // Timeouts, aborts and malformed responses all mean "not reachable now".
      return null;
    } finally {
      deadline.cancel();
      _activeProbeClients.remove(client);
      client.close(force: true);
    }
  }

  /// One `GET /v1/node` with a cancellable socket (see [_httpProbe]) when the
  /// production HTTP client is in use; injected test clients own their own
  /// completion semantics.
  Future<NodeInfo?> _fetchInfo(Uri base, Duration timeout) =>
      _client is HttpNodeClient
          ? _httpProbe(base, timeout: timeout)
          : _fetch(base, timeout, client: _client);

  Future<void> _probe(_PeerEntry entry) async {
    final info = await _fetchInfo(entry.info.baseUri, probeTimeout);
    // The entry may have been dropped or replaced by a beacon/scan meanwhile.
    if (!_started || !identical(_peers[entry.info.nodeId], entry)) return;
    if (info != null) {
      _upsert(info, host: entry.info.host, manual: entry.manual);
      return;
    }
    entry.failures++;
    if (entry.failures >= probeFailures && entry.reachable) {
      entry.reachable = false;
      _emitPeers();
    }
  }

  Future<void> _waitForProbes() async {
    while (_inFlightProbes.isNotEmpty || _inFlightManualRetries.isNotEmpty) {
      final pending = [..._inFlightProbes, ..._inFlightManualRetries];
      if (pending.isEmpty) return;
      await Future.wait(pending);
    }
  }

  @visibleForTesting
  void debugSeedPeer(NodeInfo info,
      {bool manual = false, DateTime? lastSeen, DateTime? lastProbed}) {
    _peers[info.nodeId] = _PeerEntry(info, lastSeen ?? _now(),
        manual: manual, lastProbed: lastProbed ?? lastSeen ?? _now());
  }

  @visibleForTesting
  void debugUpsert(NodeInfo info,
          {required String host, bool manual = false}) =>
      _upsert(info, host: host, manual: manual);

  @visibleForTesting
  void debugRunMaintenance() => _runMaintenance();

  /// Waits for every in-flight liveness probe to finish.
  @visibleForTesting
  Future<void> debugWaitForProbes() => _waitForProbes();

  /// Runs one maintenance pass and waits for the probes it started, so tests
  /// with a fake clock can observe the result deterministically.
  @visibleForTesting
  Future<void> debugRunMaintenanceAsync() async {
    _runMaintenance();
    await _waitForProbes();
  }

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
    // A dedicated client whose connection timeout matches the sweep timeout, so
    // dead hosts fail at the socket level and close() on stop aborts the rest.
    final shared = _client;
    final sweepClient =
        shared is HttpNodeClient ? HttpNodeClient(timeout: sweepTimeout) : null;
    _sweepClient = sweepClient;
    final client = sweepClient ?? shared;
    var next = 0;
    Future<void> worker() async {
      while (!token.cancelled) {
        final index = next++;
        if (index >= hosts.length) return;
        final host = hosts[index];
        final info = await _fetch(
            Uri(scheme: 'http', host: host, port: port), sweepTimeout,
            client: client);
        if (token.cancelled) return;
        if (info == null || info.nodeId == _selfId) continue;
        final manual = _peers[info.nodeId]?.manual ?? false;
        _upsert(info, host: host, manual: manual);
      }
    }

    final count = sweepConcurrency < 1
        ? 1
        : (sweepConcurrency > hosts.length ? hosts.length : sweepConcurrency);
    try {
      await Future.wait([for (var i = 0; i < count; i++) worker()]);
    } finally {
      sweepClient?.close();
      if (identical(_sweepClient, sweepClient)) _sweepClient = null;
    }
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
