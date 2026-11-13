// STUB – owned by engine. Replace the body; keep the class name and constructor.
import '../interfaces.dart';
import '../models.dart';

class DefaultClusterPlanner implements ClusterPlanner {
  const DefaultClusterPlanner();

  @override
  ClusterPlan plan(LocalModel model, List<PlanNode> nodes) => throw UnimplementedError();
  @override
  List<String> llamaServerArgs(ClusterPlan plan) => throw UnimplementedError();
}
