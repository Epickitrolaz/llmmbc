// core-net: pure flag/env parsing for the headless CLI memory options (§2.5, §8).
import 'dart:io';

import '../models.dart';

/// Memory basis + share resolved from CLI flags and environment variables.
class MemoryOptions {
  final MemoryBasis basis;
  final double share;

  const MemoryOptions(
      {this.basis = MemoryBasis.total, this.share = kDefaultMemoryShare});

  @override
  bool operator ==(Object other) =>
      other is MemoryOptions && other.basis == basis && other.share == share;

  @override
  int get hashCode => Object.hash(basis, share);

  @override
  String toString() => 'MemoryOptions(${basis.name}, $share)';
}

/// Resolves `--memory-basis` / `--memory-share` with `LLMMBC_MEMORY_BASIS` /
/// `LLMMBC_MEMORY_SHARE` fallbacks.
///
/// Precedence: flag, then environment, then the defaults (total / 0.7). Throws
/// [FormatException] with a user-facing message for unknown or out-of-range
/// values; the caller maps that to `bad_request`.
MemoryOptions parseMemoryOptions({
  String? basisFlag,
  String? shareFlag,
  Map<String, String> environment = const {},
}) {
  final basisRaw =
      _firstNonEmpty(basisFlag, environment['LLMMBC_MEMORY_BASIS']);
  final shareRaw =
      _firstNonEmpty(shareFlag, environment['LLMMBC_MEMORY_SHARE']);
  return MemoryOptions(
    basis: basisRaw == null ? MemoryBasis.total : parseMemoryBasis(basisRaw),
    share: shareRaw == null ? kDefaultMemoryShare : parseMemoryShare(shareRaw),
  );
}

String? _firstNonEmpty(String? flag, String? env) {
  if (flag != null && flag.trim().isNotEmpty) return flag.trim();
  if (env != null && env.trim().isNotEmpty) return env.trim();
  return null;
}

/// `total` or `available`, case-insensitive.
MemoryBasis parseMemoryBasis(String raw) {
  final value = raw.trim().toLowerCase();
  for (final basis in MemoryBasis.values) {
    if (basis.name == value) return basis;
  }
  throw FormatException(
      'invalid memory basis "$raw" (expected total or available)');
}

/// A fraction in `(0, 1]`, e.g. `0.7`.
double parseMemoryShare(String raw) {
  final value = double.tryParse(raw.trim());
  if (value == null || value.isNaN || value <= 0 || value > 1) {
    throw FormatException(
        'invalid memory share "$raw" (expected a fraction in (0, 1])');
  }
  return value;
}

/// Reads the share for commands that only take environment input (`hw`).
double memoryShareFromEnvironment(Map<String, String> environment) {
  final raw = environment['LLMMBC_MEMORY_SHARE'];
  if (raw == null || raw.trim().isEmpty) return kDefaultMemoryShare;
  return parseMemoryShare(raw);
}

/// `stdout`/`stderr` TTY detection helper shared by the CLI commands.
bool stdoutIsTty() {
  try {
    return stdout.hasTerminal;
  } on Object {
    return false;
  }
}
