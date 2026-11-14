/// Cluster memory fit estimates for the chat model picker.
///
/// The planner's real decision is made by `ClusterPlanner` on the coordinator (§2.4).
/// The picker only needs a cheap, honest estimate: the model's size and GGUF tensor
/// sizes against the summed effective budgets of its candidates.
library;

import 'package:llmmbc_core/llmmbc_core.dart';

/// How a cluster model relates to the memory its candidates lend.
enum FitState {
  /// The model fits inside the summed budgets without expert streaming.
  fits,

  /// MoE model: the whole model does not fit, but everything except the expert
  /// tensors does. With expert streaming (Settings) it can run from the workers' disks.
  needsExpertStreaming,

  /// The model does not fit even with expert streaming (or it is dense).
  doesNotFit,
}

class ModelFit {
  const ModelFit({
    required this.state,
    required this.modelBytes,
    required this.budgetBytes,
    required this.expertBytes,
    required this.nonExpertBytes,
    required this.candidateCount,
  });

  final FitState state;
  final int modelBytes;
  final int budgetBytes;
  final int expertBytes;
  final int nonExpertBytes;
  final int candidateCount;

  bool get hasCandidates => candidateCount > 0 && budgetBytes > 0;
  bool get isMoe => expertBytes > 0;

  /// True when streaming is the only way this model can run.
  bool get needsExpertStreaming =>
      hasCandidates && state == FitState.needsExpertStreaming;

  /// True when the model does not fit even with streaming (or is dense and too big).
  bool get doesNotFit => hasCandidates && state == FitState.doesNotFit;
}

/// Estimates the fit of [model] using its file size, GGUF metadata and the summed
/// [NodeInfo.effectiveBudgetBytes] of its candidates.
///
/// Expert tensors (`ffn_*_exps`) are the only bytes that may exceed a worker's
/// budget under expert streaming (§2.4), so the non-expert remainder is compared
/// with the budget. Without metadata there is no reliable expert split and the
/// model is treated like a dense one (conservative).
ModelFit estimateModelFit(ClusterModel model) {
  var budget = 0;
  for (final node in model.candidates) {
    budget += node.effectiveBudgetBytes;
  }

  final meta = model.metadata;
  final tensorBytes = meta?.totalTensorBytes ?? 0;
  final modelBytes = model.sizeBytes > 0 ? model.sizeBytes : tensorBytes;
  final rawExpert = meta?.expertTensorBytes ?? 0;
  final expertBytes = rawExpert < 0
      ? 0
      : rawExpert > modelBytes
      ? modelBytes
      : rawExpert;
  final nonExpertBytes = modelBytes - expertBytes;

  final FitState state;
  if (budget <= 0) {
    state = FitState.doesNotFit;
  } else if (modelBytes <= budget) {
    state = FitState.fits;
  } else if (expertBytes > 0 && nonExpertBytes <= budget) {
    state = FitState.needsExpertStreaming;
  } else {
    state = FitState.doesNotFit;
  }

  return ModelFit(
    state: state,
    modelBytes: modelBytes,
    budgetBytes: budget,
    expertBytes: expertBytes,
    nonExpertBytes: nonExpertBytes,
    candidateCount: model.candidates.length,
  );
}
