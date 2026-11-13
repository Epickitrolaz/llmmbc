import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs [vm_service_probe.dart] with a VM service attached (every Flutter debug build) and
/// returns its `RESULT` fields.
///
/// Regression for #68: with a VM service attached, `abort()` used to wait for the hash
/// isolate to exit, so cancels and mid-body failures never produced a terminal event.
Future<({String terminal, int elapsedMs})> _runProbe(String scenario) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    '--observe=0',
    File('test/registry/vm_service_probe.dart').absolute.path,
    scenario,
  ]);
  final output = StringBuffer();
  final exited = Completer<int>();
  process.stdout.transform(utf8.decoder).listen(output.write);
  process.stderr.transform(utf8.decoder).listen(output.write);
  unawaited(process.exitCode.then((code) {
    if (!exited.isCompleted) exited.complete(code);
  }));
  int code;
  try {
    code = await exited.future.timeout(const Duration(seconds: 25));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    fail('$scenario probe hung under a VM service (no terminal event):\n$output');
  }
  final lines = const LineSplitter()
      .convert(output.toString())
      .where((line) => line.startsWith('RESULT '));
  if (code != 0 || lines.isEmpty) {
    fail('$scenario probe failed (exit $code):\n$output');
  }
  final line = lines.last;
  final terminal = RegExp(r'terminal=(\S+)').firstMatch(line)?.group(1);
  final elapsed = int.tryParse(RegExp(r'ms=(\d+)').firstMatch(line)?.group(1) ?? '');
  if (terminal == null || elapsed == null) {
    fail('$scenario probe printed an unparsable result:\n$line');
  }
  return (terminal: terminal, elapsedMs: elapsed);
}

void main() {
  test('cancel reaches a terminal event under a VM service (#68)', () async {
    final result = await _runProbe('cancel');
    expect(result.terminal, 'cancelled');
    expect(result.elapsedMs, lessThan(2000),
        reason: 'cancel took ${result.elapsedMs}ms to reach cancelled under a VM service');
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a mid-body connection drop fails under a VM service (#68)', () async {
    final result = await _runProbe('drop');
    expect(result.terminal, 'failed');
    expect(result.elapsedMs, lessThan(2000),
        reason: 'a dropped body took ${result.elapsedMs}ms to fail under a VM service');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
