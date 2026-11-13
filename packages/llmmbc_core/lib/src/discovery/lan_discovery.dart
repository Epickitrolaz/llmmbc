// STUB – owned by core-net. Replace the body; keep the class name and constructor.
import '../interfaces.dart';
import '../models.dart';

class LanDiscovery implements Discovery {
  LanDiscovery({NodeClient? client, PlatformHooks hooks = const PlatformHooks()});

  @override
  Future<void> start(NodeInfo Function() self, NodeSettings settings) => throw UnimplementedError();
  @override
  Future<void> stop() => throw UnimplementedError();
  @override
  Future<void> scan() => throw UnimplementedError();
  @override
  List<NodeInfo> get peers => const [];
  @override
  Stream<List<NodeInfo>> get peersChanged => const Stream.empty();
  @override
  Future<NodeInfo?> addManualPeer(String hostPort) => throw UnimplementedError();
}
