// STUB – owned by engine. Replace the body; keep the class name and constructor.
import '../interfaces.dart';
import '../models.dart';

class LlamaCppEngine implements InferenceEngine {
  /// [planner] defaults to `DefaultClusterPlanner()`.
  LlamaCppEngine({required EngineLocator locator, ClusterPlanner? planner});

  @override
  Future<int> startRpcWorker({required int port, required String cacheDir}) => throw UnimplementedError();
  @override
  Future<void> stopRpcWorker() => throw UnimplementedError();
  @override
  bool get rpcWorkerRunning => false;
  @override
  Future<Uri> startCoordinator({required LocalModel model, required ClusterPlan plan, required int port}) =>
      throw UnimplementedError();
  @override
  Future<void> stopCoordinator() => throw UnimplementedError();
  @override
  bool get coordinatorRunning => false;
  @override
  List<String> get logTail => const [];
}
