import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> runCli(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      ['bin/llmmbc_node.dart', ...args],
      workingDirectory: Directory.current.path,
    );

void main() {
  test('prints usage when called without a command', () async {
    final result = await runCli(const []);
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('llmmbc_node <command>'));
    expect(result.stdout as String,
        contains('serve, pull, list, rm, hw, peers, chat'));
  });

  test('--help exits cleanly', () async {
    final result = await runCli(const ['--help']);
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('Commands: serve, pull'));
  });

  test('chat prints reasoning_content inside <think> tags (#39)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      Map<String, dynamic> chunk(Map<String, dynamic> delta,
              {String? finish}) =>
          {
            'id': 'chatcmpl-test',
            'object': 'chat.completion.chunk',
            'created': 0,
            'model': 'qwen3:0.6b',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': finish}
            ],
          };
      final response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType('text', 'event-stream');
      response.write('data: ${jsonEncode(chunk({
            'reasoning_content': 'Two plus two is four.'
          }))}\n\n');
      response.write('data: ${jsonEncode(chunk({
            'content': ' 2+2=4'
          }, finish: 'stop'))}\n\n');
      response.write('data: [DONE]\n\n');
      await response.close();
    });

    final result = await runCli([
      'chat',
      'qwen3:0.6b',
      'What is 2+2?',
      '--node',
      'http://127.0.0.1:${server.port}',
    ]);
    expect(result.exitCode, 0);
    final stdout = result.stdout as String;
    expect(stdout, contains('<think>'));
    expect(stdout, contains('Two plus two is four.'));
    expect(stdout, contains('2+2=4'));
  });
}
