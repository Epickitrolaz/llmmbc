/// Banner that explains why the node runtime fell back to UI-only mode, with
/// copyable details (dialog) and a retry action.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/runtime_failure.dart';
import 'common.dart';

class RuntimeFailureBanner extends StatelessWidget {
  const RuntimeFailureBanner({
    super.key,
    required this.failure,
    required this.onRetry,
    this.retrying = false,
  });

  final RuntimeFailure failure;
  final Future<void> Function() onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('runtime-failure'),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.45)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final details = TextButton(
            key: const Key('runtime-failure-details'),
            onPressed: () => showRuntimeFailureDialog(context, failure),
            child: const Text('Details'),
          );
          final retry = FilledButton.tonalIcon(
            key: const Key('runtime-failure-retry'),
            onPressed: retrying ? null : onRetry,
            icon: retrying
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 16),
            label: Text(retrying ? 'Retrying…' : 'Retry'),
          );
          final message = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Core runtime unavailable — UI-only mode: ${failure.summary}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                message,
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [details, const SizedBox(width: 4), retry],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: message),
              const SizedBox(width: 8),
              details,
              const SizedBox(width: 4),
              retry,
            ],
          );
        },
      ),
    );
  }
}

/// Full error details in a scrollable dialog (keeps the inline banner small).
Future<void> showRuntimeFailureDialog(BuildContext context, RuntimeFailure failure) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('runtime-failure-dialog'),
      title: const Row(
        children: [
          Icon(Icons.error_outline, size: 20),
          SizedBox(width: 8),
          Expanded(child: Text('Core runtime error')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(failure.summary),
              const SizedBox(height: 12),
              RuntimeFailureDetails(failure: failure),
            ],
          ),
        ),
      ),
      actions: [
        _CopyDetailsButton(text: failure.detailsText),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    ),
  );
}

class _CopyDetailsButton extends StatefulWidget {
  const _CopyDetailsButton({required this.text});

  final String text;

  @override
  State<_CopyDetailsButton> createState() => _CopyDetailsButtonState();
}

class _CopyDetailsButtonState extends State<_CopyDetailsButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _copy,
      icon: Icon(_copied ? Icons.check : Icons.copy_all, size: 16),
      label: Text(_copied ? 'Copied' : 'Copy details'),
    );
  }
}

/// Monospace details (phase/type/time, stack, engine log tail).
class RuntimeFailureDetails extends StatelessWidget {
  const RuntimeFailureDetails({super.key, required this.failure});

  final RuntimeFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          'phase: ${failure.phase}  ·  type: ${failure.type}  ·  ${failure.at.toIso8601String()}',
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11.5),
        ),
        if (failure.stack != null) ...[
          const SizedBox(height: 8),
          Text('Stack trace', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          CodeBlock(lines: failure.stack!.split('\n'), maxHeight: 200),
        ],
        if (failure.logTail.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Engine log tail', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          CodeBlock(lines: failure.logTail, maxHeight: 180),
        ],
        const SizedBox(height: 4),
        Text(
          'Settings, hardware, manual peers and history stay available. Retry rebuilds the node runtime.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
