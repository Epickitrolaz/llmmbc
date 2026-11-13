/// Dialog used by Cluster and Settings to add a manual peer by `host:port`.
library;

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:flutter/material.dart';

/// Returns the resolved [NodeInfo], or null when cancelled.
Future<NodeInfo?> showAddPeerDialog(
  BuildContext context, {
  required Future<NodeInfo?> Function(String hostPort) onAdd,
  String initialValue = '10.0.2.2:47101',
}) {
  return showDialog<NodeInfo?>(
    context: context,
    builder: (context) => _AddPeerDialog(onAdd: onAdd, initialValue: initialValue),
  );
}

class _AddPeerDialog extends StatefulWidget {
  const _AddPeerDialog({required this.onAdd, required this.initialValue});

  final Future<NodeInfo?> Function(String hostPort) onAdd;
  final String initialValue;

  @override
  State<_AddPeerDialog> createState() => _AddPeerDialogState();
}

class _AddPeerDialogState extends State<_AddPeerDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Enter host:port');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final node = await widget.onAdd(value);
    if (!mounted) return;
    if (node == null) {
      setState(() {
        _busy = false;
        _error = 'No node answered on that address.';
      });
    } else {
      Navigator.of(context).pop(node);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a peer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The node is resolved with GET /v1/node. Use host:port — for the Android emulator the '
              'host machine is reachable at 10.0.2.2.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('add-peer-field'),
              controller: _controller,
              autocorrect: false,
              autofocus: false,
              decoration: InputDecoration(hintText: '192.168.1.20:47101', errorText: _error),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('add-peer-submit'),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}
