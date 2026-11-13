// STUB – owned by core-net. Serves the wire protocol of docs/ARCHITECTURE.md §3.
import '../interfaces.dart';

class NodeApiServer {
  NodeApiServer(NodeService service);

  /// Binds and returns the actual port.
  Future<int> start({String host = '0.0.0.0', required int port}) => throw UnimplementedError();
  Future<void> stop() => throw UnimplementedError();
}
