/// OpenAI-compatible server-sent-events parsing shared by the node client and the
/// coordinator-side proxy.
library;

import 'dart:async';
import 'dart:convert';

import '../models.dart';

const String _openThink = '<think\u003e';
const String _closeThink = '</think\u003e';

/// Parses an OpenAI `chat/completions` SSE stream into [ChatDelta]s.
///
/// Handles `data: {...}` events and the terminating `data: [DONE]` sentinel. The
/// optional [servedBy] is copied onto every emitted delta.
///
/// Reasoning models (e.g. qwen3 with `--jinja`) emit `delta.reasoning_content`
/// instead of `delta.content`. [ChatDelta] only carries `content`, so reasoning
/// is surfaced inside `<think>…</think>` markers; clients that render `content`
/// therefore still see a non-empty answer (#39).
Stream<ChatDelta> parseOpenAiSse(Stream<List<int>> body,
    {String? servedBy}) async* {
  final lines = body.transform(utf8.decoder).transform(const LineSplitter());
  var inReasoning = false;
  await for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || !line.startsWith('data:')) continue;
    final payload = line.substring(5).trim();
    if (payload.isEmpty) continue;
    if (payload == '[DONE]') break;

    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) continue;
      json = decoded;
    } on FormatException {
      continue;
    }

    final err = json['error'];
    if (err != null) {
      final code = err is Map
          ? (err['code'] as String? ?? 'engine_error')
          : 'engine_error';
      final message = err is Map
          ? (err['message'] as String? ?? 'engine stream error')
          : err.toString();
      throw LlmmbcException(code, message);
    }

    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) continue;
    for (final choice in choices) {
      if (choice is! Map) continue;
      final rawDelta = choice['delta'] ?? choice['message'];
      final reasoning = rawDelta is Map
          ? (rawDelta['reasoning_content']?.toString() ?? '')
          : '';
      final content =
          rawDelta is Map ? (rawDelta['content']?.toString() ?? '') : '';
      final finish = choice['finish_reason'] as String?;

      if (reasoning.isNotEmpty) {
        if (!inReasoning) {
          inReasoning = true;
          yield ChatDelta(_openThink, servedBy: servedBy);
        }
        yield ChatDelta(reasoning, servedBy: servedBy);
      }
      if (content.isNotEmpty) {
        if (inReasoning) {
          inReasoning = false;
          yield ChatDelta(_closeThink, servedBy: servedBy);
        }
        yield ChatDelta(content, servedBy: servedBy);
      }
      if (finish != null) {
        if (inReasoning) {
          inReasoning = false;
          yield ChatDelta(_closeThink, servedBy: servedBy);
        }
        yield ChatDelta('', finishReason: finish, servedBy: servedBy);
      }
    }
  }
}

/// Encodes one OpenAI streaming chunk as an SSE `data:` event line.
String encodeOpenAiSseChunk({
  required String id,
  required String model,
  required int created,
  required String content,
  String? finishReason,
}) {
  final chunk = <String, dynamic>{
    'id': id,
    'object': 'chat.completion.chunk',
    'created': created,
    'model': model,
    'choices': [
      {
        'index': 0,
        'delta': content.isEmpty ? <String, dynamic>{} : {'content': content},
        'finish_reason': finishReason,
      }
    ],
  };
  return 'data: ${jsonEncode(chunk)}\n\n';
}
