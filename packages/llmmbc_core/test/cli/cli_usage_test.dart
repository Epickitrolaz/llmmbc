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
}
