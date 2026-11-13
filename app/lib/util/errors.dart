/// Turns raw failures into actionable, user facing copy.
library;

import 'package:llmmbc_core/llmmbc_core.dart';

/// A resolved error presentation: short title, explanation and a hint.
class ChatErrorInfo {
  final String code;
  final String title;
  final String message;

  const ChatErrorInfo({required this.code, required this.title, required this.message});
}

/// Maps the wire error codes of docs/ARCHITECTURE.md §3 to UI copy.
ChatErrorInfo describeChatError(Object error) {
  if (error is LlmmbcException) {
    switch (error.code) {
      case 'no_candidates':
        return ChatErrorInfo(
          code: error.code,
          title: 'No node can serve this model',
          message:
              'The cluster has no worker that has this model downloaded and worker mode enabled. '
              'Download the model on a device that runs as a worker, or turn worker mode on here.',
        );
      case 'busy':
        return const ChatErrorInfo(
          code: 'busy',
          title: 'Coordinator is busy',
          message:
              'The node that would coordinate this model is already running another session. '
              'Sessions end after 10 minutes of inactivity — try again then.',
        );
      case 'does_not_fit':
        return ChatErrorInfo(
          code: error.code,
          title: 'Model does not fit in the cluster',
          message:
              'The combined memory the cluster can lend is smaller than this model. '
              '${error.message}',
        );
      case 'engine_error':
        return ChatErrorInfo(
          code: error.code,
          title: 'Engine failed to start',
          message: error.message.isEmpty ? 'llama.cpp reported an error. Check the engine log tail in Settings.' : error.message,
        );
      case 'not_candidate':
        return ChatErrorInfo(
          code: error.code,
          title: 'Node is not a candidate',
          message: error.message.isEmpty
              ? 'That node does not have this model downloaded, or worker mode is off.'
              : error.message,
        );
      default:
        return ChatErrorInfo(
          code: error.code,
          title: 'Chat failed (${error.code})',
          message: error.message.isEmpty ? 'The node reported an unspecified error.' : error.message,
        );
    }
  }
  final text = error.toString();
  if (text.contains('SocketException') || text.contains('Connection refused')) {
    return const ChatErrorInfo(
      code: 'network',
      title: 'Cannot reach the coordinator',
      message: 'The connection to the node failed. Check that both devices are on the same LAN and retry.',
    );
  }
  if (text.contains('TimeoutException')) {
    return const ChatErrorInfo(
      code: 'timeout',
      title: 'The node did not answer in time',
      message: 'The cluster is taking too long to start a session. Retry in a moment.',
    );
  }
  return ChatErrorInfo(
    code: 'internal',
    title: 'Something went wrong',
    message: text.isEmpty ? 'Unknown error.' : text,
  );
}
