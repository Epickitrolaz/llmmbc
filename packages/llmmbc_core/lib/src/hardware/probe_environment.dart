/// Host access used by [LocalHardwareProbe].
///
/// Wrapping file/process access in a small injectable object keeps the probe testable: tests
/// substitute fixture text and canned command output for every platform while production uses
/// the real host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Result of a short-lived probe command.
class ProbeCommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const ProbeCommandResult(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;
}

/// Hard cap for every command the probe shells out to. Hardware probing must never hang node
/// startup (a missing GPU driver can otherwise block `nvidia-smi` forever).
const Duration kProbeCommandTimeout = Duration(seconds: 3);

typedef FileTextReader = String? Function(String path);
typedef CommandInvoker = Future<ProbeCommandResult?> Function(
    String executable, List<String> arguments);
typedef DirectoryLister = Future<List<String>> Function(String path);

class ProbeEnvironment {
  /// `Platform.operatingSystem`: `linux`, `android`, `macos`, `windows`, `ios`.
  final String platform;

  /// Returns the file contents, or null when the file is missing/unreadable.
  final FileTextReader readFile;

  /// Runs a command with a short timeout; null when it could not be started or timed out.
  final CommandInvoker run;

  /// Lists a directory (absolute paths of entries); empty when missing/unreadable.
  final DirectoryLister listDirectory;

  /// Environment variable lookup.
  final String? Function(String name) env;

  /// Logical processor count (fallback when `/proc/cpuinfo` is unavailable).
  final int processorCount;

  /// Dart ABI string, used as an architecture fallback (`linux_x64`, `androidArm64`, ...).
  final String abi;

  const ProbeEnvironment({
    required this.platform,
    required this.readFile,
    required this.run,
    required this.listDirectory,
    required this.env,
    required this.processorCount,
    required this.abi,
  });

  factory ProbeEnvironment.real() => ProbeEnvironment(
        platform: Platform.operatingSystem,
        readFile: _readTextFile,
        run: _runCommand,
        listDirectory: _listDirectory,
        env: (name) => Platform.environment[name],
        processorCount: Platform.numberOfProcessors,
        abi: Abi.current().toString(),
      );
}

String? _readTextFile(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    // Some /proc and device-tree files contain NUL padding; decode leniently.
    return utf8.decode(file.readAsBytesSync(), allowMalformed: true);
  } catch (_) {
    return null;
  }
}

Future<List<String>> _listDirectory(String path) async {
  try {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    final entries = await dir.list(followLinks: false).map((e) => e.path).toList();
    return entries;
  } catch (_) {
    return const [];
  }
}

Future<ProbeCommandResult?> _runCommand(String executable, List<String> arguments) async {
  Process? process;
  try {
    process = await Process.start(executable, arguments);
    // Drain both pipes concurrently so a chatty child cannot block on a full pipe.
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitFuture = process.exitCode;
    final results = await Future.wait<Object?>([stdoutFuture, stderrFuture, exitFuture])
        .timeout(kProbeCommandTimeout);
    return ProbeCommandResult(
      results[2] as int,
      results[0] as String,
      results[1] as String,
    );
  } catch (_) {
    try {
      process?.kill(ProcessSignal.sigkill);
    } catch (_) {
      // Ignore: the process may already be gone.
    }
    return null;
  }
}
