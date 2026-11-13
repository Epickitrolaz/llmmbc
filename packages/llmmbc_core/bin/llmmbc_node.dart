// core-net: headless node CLI (docs/ARCHITECTURE.md §8).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:path/path.dart' as p;

const String _kDefaultNode = 'http://127.0.0.1:47101';

Future<void> main(List<String> args) async {
  final parser = ArgParser();
  parser.addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  parser.addCommand('serve')
    ..addOption('data-dir', help: 'Data directory')
    ..addOption('name', help: 'Node display name')
    ..addFlag('no-worker',
        negatable: false, help: 'Do not lend compute to sessions')
    ..addMultiOption('peer', help: 'Manual peer host:port', splitCommas: true)
    ..addOption('port', defaultsTo: '$kNodeApiPort', help: 'Node API port');

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

  final service = await LocalNodeService.create(
    settingsPath: settingsPath,
    defaultDataDir: dataDir,
    platform: const PlatformHooks(),
  );

  var settings = service.settings;
  final name = command['name'] as String? ?? env['LLMMBC_NAME'];
  if (name != null && name.isNotEmpty) settings = settings.copyWith(name: name);

  var workerEnabled = !(command['no-worker'] as bool);
  final workerEnv = env['LLMMBC_WORKER'];
  if (workerEnv != null) {
    workerEnabled = workerEnv != '0' && workerEnv.toLowerCase() != 'false';
  }
  settings = settings.copyWith(workerEnabled: workerEnabled);

  final port =
      int.tryParse(command['port'] as String? ?? '') ?? settings.apiPort;
  settings = settings.copyWith(apiPort: port);

  final peers = <String>{
    ...(command['peer'] as List<String>),
    ...?(env['LLMMBC_PEERS']
        ?.split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)),
  };
  settings = settings.copyWith(manualPeers: peers.toList());
  await service.updateSettings(settings);

  final phases = service.startupPhase.listen((phase) {
    stdout.writeln('startup: $phase');
  });

  stdout.writeln('llmmbc_node starting (data: $dataDir, api: $port)');
  await service.start();
  stdout
      .writeln('node ${service.self.name} ${service.self.nodeId} listening on '
          'http://${service.self.host}:${service.self.apiPort}');
  stdout.writeln(
      'worker: ${service.self.workerEnabled ? "enabled" : "disabled"}  '
      'engine: ${service.self.engineAvailable ? "available" : "unavailable"}');
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
  var last = -1;
  await for (final progress in store.pull(ref)) {
    final pct = (progress.fraction * 100).floor();
    if (pct != last || progress.state != DownloadState.downloading) {
      last = pct;
      stdout.writeln(
          '${progress.state.name} $pct% ${progress.receivedBytes}/${progress.totalBytes}');
    }
    if (progress.state == DownloadState.failed) {
      throw LlmmbcException('internal', progress.error ?? 'download failed');
    }
    if (progress.state == DownloadState.cancelled) {
      exitCode = 1;
      return;
    }
  }
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
