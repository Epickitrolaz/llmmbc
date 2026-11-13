/// Shows the four startup phases of docs/ARCHITECTURE.md §2.1.
library;

import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../app/llmmbc_app.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/runtime_failure_banner.dart';

class _Step {
  final String key;
  final String title;
  final String detail;
  final IconData icon;

  const _Step(this.key, this.title, this.detail, this.icon);
}

const List<_Step> _steps = [
  _Step('settings', 'Settings', 'Node identity and preferences', Icons.tune),
  _Step('hardware', 'Hardware scan', 'RAM, CPU and GPUs', Icons.memory),
  _Step('models', 'Model scan', 'Local GGUF model store', Icons.inventory_2_outlined),
  _Step('api', 'Node API', 'Bind TCP 47101 and load the engine', Icons.dns_outlined),
  _Step('network', 'Network scan', 'UDP beacon, subnet sweep, manual peers', Icons.wifi_find),
];

/// Phases emitted by `LocalNodeService` run in this order: settings, hardware,
/// models, api, discovery, ready. Older/degraded services emit `network` instead
/// of `discovery`, so treat both as the last step; unknown phases keep the
/// previous step active instead of resetting progress.
int _stepIndexOfPhase(String phase) {
  switch (phase) {
    case 'settings':
      return 0;
    case 'hardware':
      return 1;
    case 'models':
      return 2;
    case 'api':
      return 3;
    case 'discovery':
    case 'network':
      return 4;
    default:
      return -1;
  }
}

int _lastStepIndex(List<String> phases) {
  for (var i = phases.length - 1; i >= 0; i--) {
    final index = _stepIndexOfPhase(phases[i]);
    if (index >= 0) return index;
  }
  return -1;
}

class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context);
    final theme = Theme.of(context);
    final phases = session.phases;
    final ready = session.ready;
    final failed = session.startupError != null;
    final lastPhaseIndex = _lastStepIndex(phases);
    final progress = ready
        ? 1.0
        : phases.isEmpty
            ? 0.05
            : ((lastPhaseIndex + 1) / _steps.length).clamp(0.0, 1.0);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const BrandMark(size: 56),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('LLMMBC', style: theme.textTheme.headlineSmall),
                            Text(
                              'LLM Mobile Cluster',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: StatusPill(
                      label: session.buildModeLabel,
                      color: session.fake ? theme.colorScheme.tertiary : theme.colorScheme.primary,
                      icon: session.fake ? Icons.science_outlined : Icons.hub_outlined,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    failed ? 'Startup failed' : ready ? 'Node ready' : 'Starting this node',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    failed
                        ? 'The node runtime reported an error. You can retry; settings and peers stay untouched.'
                        : 'Every node loads settings, scans its hardware and models, then joins the LAN cluster.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 22),
                  for (var i = 0; i < _steps.length; i++)
                    _PhaseRow(
                      step: _steps[i],
                      state: _stateFor(i, phases: phases, ready: ready, failed: failed),
                      detail: i == lastPhaseIndex && !ready && !failed ? 'in progress…' : _steps[i].detail,
                    ),
                  const SizedBox(height: 22),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: failed ? null : progress,
                      minHeight: 4,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      color: failed ? theme.colorScheme.error : theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (failed)
                    PanelCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.error_outline, color: theme.colorScheme.error, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  session.startupError!,
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                                ),
                              ),
                            ],
                          ),
                          if (session.runtimeFailure != null) ...[
                            const SizedBox(height: 10),
                            RuntimeFailureDetails(failure: session.runtimeFailure!),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              FilledButton.icon(
                                key: const Key('startup-retry'),
                                onPressed: session.retryingRuntime ? null : session.retryRuntime,
                                icon: session.retryingRuntime
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.refresh),
                                label: Text(session.retryingRuntime ? 'Retrying…' : 'Retry startup'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      children: [
                        Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'No account or cloud service: devices pair automatically over the LAN.',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  _PhaseState _stateFor(
    int index, {
    required List<String> phases,
    required bool ready,
    required bool failed,
  }) {
    final reached = _lastStepIndex(phases);
    if (failed) {
      if (index <= reached) return _PhaseState.done;
      if (index == reached + 1) return _PhaseState.failed;
      return _PhaseState.pending;
    }
    if (ready) return _PhaseState.done;
    if (index < reached) return _PhaseState.done;
    if (index == reached) return _PhaseState.active;
    return _PhaseState.pending;
  }
}

enum _PhaseState { pending, active, done, failed }

class _PhaseRow extends StatelessWidget {
  const _PhaseRow({required this.step, required this.state, required this.detail});

  final _Step step;
  final _PhaseState state;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = state == _PhaseState.active;
    final done = state == _PhaseState.done;
    final failed = state == _PhaseState.failed;
    final color = failed
        ? scheme.error
        : done
            ? scheme.primary
            : active
                ? scheme.primary
                : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: active
                ? Padding(
                    padding: const EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary),
                  )
                : Icon(
                    failed ? Icons.error_outline : done ? Icons.check_circle : Icons.circle_outlined,
                    size: 22,
                    color: failed || done ? color : scheme.outlineVariant,
                  ),
          ),
          const SizedBox(width: 12),
          Icon(step.icon, size: 16, color: color.withValues(alpha: done || active || failed ? 1 : 0.55)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: active || done ? FontWeight.w600 : FontWeight.w400,
                    color: state == _PhaseState.pending ? scheme.onSurfaceVariant : scheme.onSurface,
                  ),
                ),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
