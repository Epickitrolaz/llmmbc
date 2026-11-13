// STUB – owned by core-net. Replace the body; keep the class name and constructor.
import '../interfaces.dart';
import '../models.dart';

class HttpNodeClient implements NodeClient {
  HttpNodeClient({Duration timeout = const Duration(seconds: 5)});

  @override
  Future<NodeInfo> info(Uri base) => throw UnimplementedError();
  @override
  Future<List<NodeInfo>> peers(Uri base) => throw UnimplementedError();
  @override
  Future<({String host, int port, int budgetBytes})> startRpc(Uri base,
          {required String sessionId, required ModelRef model, required String coordinatorId}) =>
      throw UnimplementedError();
  @override
  Future<void> stopRpc(Uri base, String sessionId) => throw UnimplementedError();
  @override
  Stream<ChatDelta> chat(Uri base, ModelRef model, List<ChatMessage> messages,
          {double? temperature, int? maxTokens}) =>
      throw UnimplementedError();
  @override
  Future<SessionInfo?> session(Uri base) => throw UnimplementedError();
}
