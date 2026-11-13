import 'dart:convert';

import 'package:llmmbc_core/src/api/sse.dart';
import 'package:test/test.dart';

Stream<List<int>> sse(List<Map<String, dynamic>> chunks) {
  final body = StringBuffer();
  for (final chunk in chunks) {
    body.write('data: ${jsonEncode(chunk)}\n\n');
  }
  body.write('data: [DONE]\n\n');
  return Stream.value(utf8.encode(body.toString()));
}

Map<String, dynamic> chunk(Map<String, dynamic> delta, {String? finish}) => {
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish}
      ],
    };

void main() {
  test('passes plain content through unchanged', () async {
    final deltas = await parseOpenAiSse(sse([
      chunk({'content': 'Hello'}),
      chunk({'content': ' world'}, finish: 'stop'),
    ])).toList();
    expect(deltas.map((d) => d.content).join(), 'Hello world');
    expect(deltas.last.finishReason, 'stop');
  });

  test('surfaces reasoning_content inside <think> markers (#39)', () async {
    final deltas = await parseOpenAiSse(sse([
      chunk({'reasoning_content': 'Okay, '}),
      chunk({'reasoning_content': 'so 2+2 is 4.'}),
      chunk({'content': 'The answer is 4.'}, finish: 'stop'),
    ])).toList();

    final text = deltas.map((d) => d.content).join();
    expect(text, startsWith('<think>Okay, so 2+2 is 4.</think>'));
    expect(text, endsWith('The answer is 4.'));
    // Only one opening and one closing marker across all reasoning chunks.
    expect('<think>'.allMatches(text), hasLength(1));
    expect('</think>'.allMatches(text), hasLength(1));
    expect(deltas.last.finishReason, 'stop');
  });

  test('closes an unterminated reasoning block on a length finish (#39)',
      () async {
    final deltas = await parseOpenAiSse(sse([
      chunk({'reasoning_content': 'thinking...'}),
      chunk(<String, dynamic>{}, finish: 'length'),
    ])).toList();
    final text = deltas.map((d) => d.content).join();
    expect(text, '<think>thinking...</think>');
    expect(deltas.last.finishReason, 'length');
  });

  test('a reasoning-only stream is not empty', () async {
    final deltas = await parseOpenAiSse(sse([
      chunk({'reasoning_content': 'only reasoning'}),
    ])).toList();
    expect(deltas.map((d) => d.content).join(), '<think>only reasoning');
  });
}
