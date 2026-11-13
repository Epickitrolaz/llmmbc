import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

const ModelRef _model = ModelRef('qwen3', tag: '0.6b');
const List<ChatMessage> _messages = [ChatMessage('user', 'hi')];

Map<String, dynamic> _chunk(Map<String, dynamic> delta, {String? finish}) => {
      'id': 'chatcmpl-test',
      'object': 'chat.completion.chunk',
      'created': 0,
      'model': 'qwen3:0.6b',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish}
      ],
    };

String _event(Map<String, dynamic> chunk) => 'data: ${jsonEncode(chunk)}\n\n';

Future<void> _okHeaders(HttpResponse response) async {
  response.statusCode = 200;
  response.headers.contentType =
      ContentType('text', 'event-stream', charset: 'utf-8');
  response.bufferOutput = false;
}

void main() {
  test('chat first-byte timeout is long and separate from the API timeout',
      () async {
    final client = HttpNodeClient();
    addTearDown(client.close);
    expect(client.timeout, const Duration(seconds: 5));
    expect(
        client.chatTimeout, greaterThanOrEqualTo(const Duration(minutes: 10)));
    expect(client.chatIdleTimeout, greaterThan(Duration.zero));
  });

  test('forwards apply the coordinator routing header only when requested',
      () async {
    final seen = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      seen.add(request.headers.value(kHeaderChatRoute));
      await request.drain<void>();
      try {
        await _okHeaders(request.response);
        request.response
            .write(_event(_chunk({'content': 'ok'}, finish: 'stop')));
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      } on Object {
        // The client may already have gone away.
      }
    });

    final client = HttpNodeClient(chatTimeout: const Duration(seconds: 5));
    addTearDown(client.close);
    final base = Uri.parse('http://127.0.0.1:${server.port}');

    final routed = await client
        .chat(base, _model, _messages, asCoordinator: true)
        .toList();
    expect(routed.map((d) => d.content).join(), 'ok');
    final local = await client.chat(base, _model, _messages).toList();
    expect(local.map((d) => d.content).join(), 'ok');

    expect(seen, [kRouteCoordinator, null]);
  });

  test('a coordinator that delays the first byte does not hit the API timeout',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      // Longer than a 5 s-style default but shorter than the configured chat
      // timeout below; this models a cold model load (#39).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        await _okHeaders(request.response);
        request.response
            .write(_event(_chunk({'content': 'late'}, finish: 'stop')));
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      } on Object {
        // ignore
      }
    });

    final client = HttpNodeClient(
      timeout: const Duration(milliseconds: 50),
      chatTimeout: const Duration(seconds: 5),
    );
    addTearDown(client.close);
    final deltas = await client
        .chat(Uri.parse('http://127.0.0.1:${server.port}'), _model, _messages)
        .toList();
    expect(deltas.map((d) => d.content).join(), 'late');
  });

  test('chat fails with engine_error when the first byte never arrives',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        await _okHeaders(request.response);
        await request.response.close();
      } on Object {
        // ignore
      }
    });

    final client =
        HttpNodeClient(chatTimeout: const Duration(milliseconds: 100));
    addTearDown(client.close);
    await expectLater(
      client
          .chat(Uri.parse('http://127.0.0.1:${server.port}'), _model, _messages)
          .toList(),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having((e) => e.message, 'message', contains('timed out'))),
    );
  });

  test('a silent stream fails with the idle timeout instead of hanging (#39)',
      () async {
    final gate = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      try {
        await _okHeaders(request.response);
        request.response.write(_event(_chunk({'content': 'first'})));
        await request.response.flush();
        await gate.future;
        await request.response.close();
      } on Object {
        // ignore
      }
    });

    final client = HttpNodeClient(
      chatTimeout: const Duration(seconds: 5),
      chatIdleTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await server.close(force: true);
      try {
        client.close();
      } on Object {
        // The stalled HTTP connection is torn down with the test.
      }
    });
    await expectLater(
      client
          .chat(Uri.parse('http://127.0.0.1:${server.port}'), _model, _messages)
          .toList(),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having((e) => e.message, 'message', contains('stalled'))),
    );
  });
}
