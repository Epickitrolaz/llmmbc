// core-net: `serve` flag/env application (docs/ARCHITECTURE.md §8).
//
// Every serve option is an *override*: a plain `serve` must keep the persisted
// `NodeSettings` untouched (issues #59, #60). Only values explicitly supplied
// on the command line or via the documented environment variables are applied;
// explicit peers are merged with the persisted manual peers, de-duplicated.
import 'package:args/args.dart';

import '../constants.dart';
import '../models.dart';
import 'cli_memory.dart';

/// The `serve` sub-command parser. Shared with tests so flag parsing is
/// exercised exactly as the CLI does it.
ArgParser buildServeCommandParser() => ArgParser()
  ..addOption('data-dir', help: 'Data directory')
  ..addOption('name', help: 'Node display name')
  ..addFlag('no-worker',
      negatable: false, help: 'Do not lend compute to sessions')
  ..addMultiOption('peer',
      help: 'Manual peer host:port (merged with persisted peers)',
      splitCommas: true)
  ..addOption('port', defaultsTo: '$kNodeApiPort', help: 'Node API port')
  ..addOption('memory-basis',
      allowed: ['total', 'available'],
      help: 'Memory the budget is based on (env LLMMBC_MEMORY_BASIS)')
  ..addOption('memory-share',
      help: 'Fraction (0..1] of that memory lent to sessions '
          '(env LLMMBC_MEMORY_SHARE, default $kDefaultMemoryShare)')
  ..addFlag('allow-expert-streaming',
      negatable: true,
      help: 'MoE only: let expert weights on workers exceed their budgets and '
          'stream from their disks (env LLMMBC_EXPERT_STREAMING=0|1)');

/// Explicit overrides parsed from one `serve` invocation.
class ServeRequest {
  final String? name;

  /// null when neither `--no-worker` nor `LLMMBC_WORKER` was supplied.
  final bool? workerEnabled;
  final int? port;

  /// null when no peer was supplied; otherwise the explicit peers (de-duped).
  final List<String>? peers;
  final MemoryOverrides memory;

  /// null when neither the flag nor `LLMMBC_EXPERT_STREAMING` was supplied.
  final bool? allowExpertStreaming;

  const ServeRequest({
    this.name,
    this.workerEnabled,
    this.port,
    this.peers,
    this.memory = const MemoryOverrides(),
    this.allowExpertStreaming,
  });
}

/// Collects the explicit overrides of a parsed `serve` command.
///
/// Throws [FormatException] for invalid port/memory values.
ServeRequest serveRequestFromArgs(
  ArgResults command, {
  Map<String, String> environment = const {},
}) {
  String? name;
  if (command.wasParsed('name')) {
    final value = command['name'] as String?;
    if (value != null && value.trim().isNotEmpty) name = value.trim();
  } else {
    final envName = environment['LLMMBC_NAME'];
    if (envName != null && envName.trim().isNotEmpty) name = envName.trim();
  }

  bool? workerEnabled;
  if (command.wasParsed('no-worker')) {
    workerEnabled = false;
  } else {
    final raw = environment['LLMMBC_WORKER'];
    if (raw != null && raw.trim().isNotEmpty) {
      final value = raw.trim().toLowerCase();
      workerEnabled = value != '0' && value != 'false';
    }
  }

  int? port;
  if (command.wasParsed('port')) {
    final raw = command['port'] as String? ?? '';
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      throw FormatException('invalid port "$raw"');
    }
    port = parsed;
  }

  final peers = <String>{};
  var peersGiven = false;
  if (command.wasParsed('peer')) {
    peersGiven = true;
    peers.addAll((command['peer'] as List<String>)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty));
  }
  final rawEnvPeers = environment['LLMMBC_PEERS'];
  if (rawEnvPeers != null) {
    final envPeers = rawEnvPeers
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (envPeers.isNotEmpty) {
      peersGiven = true;
      peers.addAll(envPeers);
    }
  }

  bool? allowExpertStreaming;
  if (command.wasParsed('allow-expert-streaming')) {
    // `--allow-expert-streaming` / `--no-allow-expert-streaming`.
    allowExpertStreaming = command['allow-expert-streaming'] as bool;
  } else {
    final raw = environment['LLMMBC_EXPERT_STREAMING'];
    if (raw != null && raw.trim().isNotEmpty) {
      final value = raw.trim().toLowerCase();
      if (value == '1' || value == 'true') {
        allowExpertStreaming = true;
      } else if (value == '0' || value == 'false') {
        allowExpertStreaming = false;
      } else {
        throw FormatException(
            'invalid LLMMBC_EXPERT_STREAMING "$raw" (expected 0 or 1)');
      }
    }
  }

  return ServeRequest(
    name: name,
    workerEnabled: workerEnabled,
    port: port,
    peers: peersGiven ? peers.toList() : null,
    allowExpertStreaming: allowExpertStreaming,
    memory: parseMemoryOverrides(
      basisFlag: command.wasParsed('memory-basis')
          ? command['memory-basis'] as String?
          : null,
      shareFlag: command.wasParsed('memory-share')
          ? command['memory-share'] as String?
          : null,
      environment: environment,
    ),
  );
}

/// Applies only the explicit [request] overrides on top of [persisted].
///
/// A plain serve (`ServeRequest()` with empty environment) returns settings
/// equal to [persisted].
NodeSettings applyServeRequest(NodeSettings persisted, ServeRequest request) {
  var next = persisted;
  final name = request.name;
  if (name != null && name.trim().isNotEmpty) {
    next = next.copyWith(name: name.trim());
  }
  final workerEnabled = request.workerEnabled;
  if (workerEnabled != null) {
    next = next.copyWith(workerEnabled: workerEnabled);
  }
  final port = request.port;
  if (port != null) {
    next = next.copyWith(apiPort: port);
  }
  final peers = request.peers;
  if (peers != null) {
    next = next.copyWith(
      manualPeers: <String>{...persisted.manualPeers, ...peers}.toList(),
    );
  }
  final memory = request.memory;
  if (memory.basis != null || memory.share != null) {
    next = next.copyWith(memoryBasis: memory.basis, memoryShare: memory.share);
  }
  final allowExpertStreaming = request.allowExpertStreaming;
  if (allowExpertStreaming != null) {
    next = next.copyWith(allowExpertStreaming: allowExpertStreaming);
  }
  return next;
}
