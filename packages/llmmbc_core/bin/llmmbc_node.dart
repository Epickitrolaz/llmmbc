// core-net: headless node CLI (docs/ARCHITECTURE.md §8).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:llmmbc_core/src/node/cli_memory.dart';
import 'package:llmmbc_core/src/node/cli_progress.dart';
import 'package:llmmbc_core/src/node/cli_serve.dart';
import 'package:path/path.dart' as p;

const String _kDefaultNode = 'http://127.0.0.1:47101';

Future<void> main(List<String> args) async {
  final parser = ArgParser();
  parser.addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  parser.addCommand('serve', buildServeCommandParser());

  parser.addCommand('pull').addOption('data-dir', help: 'Data directory');

  parser.addCommand('list').addOption('data-dir', help: 'Data directory');

  parser.addCommand('rm').addOption('data-dir', help: 'Data directory');

  parser.addCommand('hw');

  parser
      .addCommand('peers')
      .addOption('node', defaultsTo: _kDefaultNode, help: 'Node base URL');

  parser.addCommand('chat')
    ..addOption('node', defaultsTo: _kDefaultNode, help: 'Node base URL')
    ..addOption('temperature', help: 'Sampling temperature')
    ..addOption('max-tokens', help: 'Maximum response tokens');

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (args.isEmpty || parsed['help'] == true) {
    _printUsage(parser);
    return;
  }

  final command = parsed.command;
  if (command == null) {
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  try {
    switch (command.name) {
      case 'serve':
        await _serve(command);
      case 'pull':
        await _pull(command);
      case 'list':
        await _list(command);
      case 'rm':
        await _rm(command);
      case 'hw':
        await _hw();
      case 'peers':
        await _peers(command);
      case 'chat':
        await _chat(command);
      default:
        _printUsage(parser);
        exitCode = 64;
    }
  } on LlmmbcException catch (e) {
    stderr.writeln('${e.code}: ${e.message}');
    exitCode = 1;
  } on Object catch (e) {
    stderr.writeln('error: $e');
    exitCode = 1;
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln('llmmbc_node <command> [options]');
  stdout.writeln('');
  stdout.writeln('Commands: serve, pull, list, rm, hw, peers, chat');
  stdout.writeln('');
  stdout.writeln(parser.usage);
}

String _home() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

String _dataDir(ArgResults command) {
  final flag = command['data-dir'] as String?;
  final env = Platform.environment['LLMMBC_DATA_DIR'];
  final dir = flag ?? env ?? p.join(_home(), '.llmmbc');
  return p.absolute(dir);
}

Future<void> _serve(ArgResults command) async {
  final dataDir = _dataDir(command);
  final env = Platform.environment;
  final settingsPath = p.join(dataDir, 'settings.json');

  final ServeRequest request;
  try {
    request = serveRequestFromArgs(command, environment: env);
  } on FormatException catch (e) {
    throw LlmmbcException('bad_request', e.message);
  }

  final service = await LocalNodeService.create(
    settingsPath: settingsPath,
    defaultDataDir: dataDir,
    platform: const PlatformHooks(),
  );

  // Every serve option is an override: a plain serve keeps the persisted
  // settings, explicit peers are merged with the persisted manual peers.
  final settings = applyServeRequest(service.settings, request);
  await service.updateSettings(settings);

  final phases = service.startupPhase.listen((phase) {
    stdout.writeln('startup: $phase');
  });

  stdout.writeln('llmmbc_node starting (data: $dataDir, '
      'api: ${service.settings.apiPort})');
  await service.start();
  stdout
      .writeln('node ${service.self.name} ${service.self.nodeId} listening on '
          'http://${service.self.host}:${service.self.apiPort}');
  stdout.writeln(
      'worker: ${service.self.workerEnabled ? "enabled" : "disabled"}  '
      'engine: ${service.self.engineAvailable ? "available" : "unavailable"}');
  stdout.writeln('memory budget: '
      '${formatByteSize(service.self.memoryBudgetBytes)} '
      '(basis ${service.settings.memoryBasis.name}, '
      'share ${service.settings.memoryShare.toStringAsFixed(2)})');
  stdout.writeln('expert streaming: '
      '${service.settings.allowExpertStreaming ? "enabled" : "disabled"}');
  stdout.writeln('peers: ${service.discovery.peers.length}');

  final changed = service.changed.listen((_) {
    stdout.writeln('peers: ${service.discovery.peers.length}  '
        'session: ${service.currentSession?.sessionId ?? "none"}');
  });

  final done = Completer<void>();
  void finish(String signal) {
    if (done.isCompleted) return;
    stdout.writeln('received $signal, shutting down');
    done.complete();
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  try {
    subscriptions
        .add(ProcessSignal.sigint.watch().listen((_) => finish('SIGINT')));
  } on Object {
    // Signal watching unsupported on this platform.
  }
  try {
    subscriptions
        .add(ProcessSignal.sigterm.watch().listen((_) => finish('SIGTERM')));
  } on Object {
    // Signal watching unsupported on this platform.
  }

  await done.future;
  await changed.cancel();
  await phases.cancel();
  for (final sub in subscriptions) {
    await sub.cancel();
  }
  await service.stop();
  stdout.writeln('stopped');
}

Future<void> _pull(ArgResults command) async {
  if (command.rest.isEmpty) {
    throw LlmmbcException('bad_request', 'usage: llmmbc_node pull <model-ref>');
  }
  final ref = ModelRef.parse(command.rest.first);
  final store = FileModelStore(_dataDir(command));
  final stopwatch = Stopwatch()..start();
  final printer = PullProgressPrinter(
    write: stdout.write,
    isTty: stdoutIsTty(),
  );
  DownloadProgress? completed;
  await for (final progress in store.pull(ref)) {
    switch (progress.state) {
      case DownloadState.failed:
        printer.finish(formatPullProgress(progress));
        throw LlmmbcException('internal', progress.error ?? 'download failed');
      case DownloadState.cancelled:
        printer.finish(formatPullProgress(progress));
        exitCode = 1;
        return;
      case DownloadState.done:
        completed = progress;
      case DownloadState.queued:
      case DownloadState.resolving:
      case DownloadState.downloading:
      case DownloadState.verifying:
        printer.update(progress);
    }
  }
  stopwatch.stop();
  var totalBytes = completed?.totalBytes ?? 0;
  if (totalBytes <= 0) {
    totalBytes = (await store.find(ref))?.sizeBytes ?? 0;
  }
  printer.finish(formatPullSummary(
    ref: ref,
    totalBytes: totalBytes,
    elapsed: stopwatch.elapsed,
  ));
}

Future<void> _list(ArgResults command) async {
  final store = FileModelStore(_dataDir(command));
  final models = await store.list();
  if (models.isEmpty) {
    stdout.writeln('no models');
    return;
  }
  final sorted = [...models]
    ..sort((a, b) => a.ref.toString().compareTo(b.ref.toString()));
  for (final model in sorted) {
    stdout.writeln('${model.ref}\t${model.sizeBytes} bytes\t${model.ggufPath}');
  }
}

Future<void> _rm(ArgResults command) async {
  if (command.rest.isEmpty) {
    throw LlmmbcException('bad_request', 'usage: llmmbc_node rm <model-ref>');
  }
  final ref = ModelRef.parse(command.rest.first);
  await FileModelStore(_dataDir(command)).delete(ref);
  stdout.writeln('removed $ref');
}

Future<void> _hw() async {
  final profile = await LocalHardwareProbe().scan();
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(profile.toJson()));
  final share = memoryShareFromEnvironment(Platform.environment);
  stdout.writeln('memory budget (share ${share.toStringAsFixed(2)}):');
  for (final basis in MemoryBasis.values) {
    final budget = profile.memoryBudgetBytes(basis, share);
    stdout.writeln('  ${basis.name.padRight(9)} '
        '${formatByteSize(budget)} ($budget bytes)');
  }
}

Future<void> _peers(ArgResults command) async {
  final base = Uri.parse(command['node'] as String);
  final client = HttpNodeClient();
  try {
    final peers = await client.peers(base);
    if (peers.isEmpty) {
      stdout.writeln('no peers');
      return;
    }
    for (final peer in peers) {
      stdout.writeln(
          '${peer.nodeId}\t${peer.name}\t${peer.host}:${peer.apiPort}\t'
          '${peer.models.length} models\t${peer.reachable ? "reachable" : "stale"}');
    }
  } finally {
    client.close();
  }
}

Future<void> _chat(ArgResults command) async {
  if (command.rest.length < 2) {
    throw LlmmbcException(
        'bad_request', 'usage: llmmbc_node chat <model-ref> <prompt>');
  }
  final ref = ModelRef.parse(command.rest.first);
  final prompt = command.rest.sublist(1).join(' ');
  final base = Uri.parse(command['node'] as String);
  final client = HttpNodeClient();
  try {
    final temperature =
        double.tryParse(command['temperature'] as String? ?? '');
    final maxTokens = int.tryParse(command['max-tokens'] as String? ?? '');
    await for (final delta in client.chat(
      base,
      ref,
      [ChatMessage('user', prompt)],
      temperature: temperature,
      maxTokens: maxTokens,
    )) {
      stdout.write(delta.content);
    }
    stdout.writeln();
  } finally {
    client.close();
  }
}
