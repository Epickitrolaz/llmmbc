import 'dart:ffi';
import 'dart:io';

import '../interfaces.dart';

/// Environment for engine child processes: prepends [binDir] to the dynamic
/// loader path (`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) and `PATH` so the shared
/// libraries shipped next to the binaries are found without relying on rpath.
Map<String, String> engineProcessEnvironment(String binDir,
    {Map<String, String>? environment}) {
  final env = Map<String, String>.of(environment ?? Platform.environment);
  final sep = Platform.isWindows ? ';' : ':';

  void prepend(String key) {
    final current = env[key];
    env[key] =
        (current == null || current.isEmpty) ? binDir : '$binDir$sep$current';
  }

  prepend('PATH');
  if (Platform.isAndroid || Platform.isLinux) {
    prepend('LD_LIBRARY_PATH');
  } else if (Platform.isMacOS) {
    prepend('DYLD_LIBRARY_PATH');
  }
  return env;
}

/// Finds the llama.cpp executables on this device.
///
/// Search order (docs/ARCHITECTURE.md §6):
/// 1. `LLMMBC_ENGINE_DIR` environment variable
/// 2. `engineDir` (from `NodeSettings.engineDir`)
/// 3. Android: `PlatformHooks.nativeLibraryDir` (binaries shipped as
///    `libllama_server.so` / `librpc_server.so` in `jniLibs`)
/// 4. desktop: `<directory of the running executable>/engine`
/// 5. dev fallback: `<repo>/native/out/<platform>-<arch>`
///
/// A directory only counts when it contains *both* binaries and both are
/// executable, so the engine can never half-start.
class DefaultEngineLocator implements EngineLocator {
  DefaultEngineLocator({
    String? engineDir,
    PlatformHooks hooks = const PlatformHooks(),
    Map<String, String>? environment,
    bool devFallback = true,
  })  : _engineDir = engineDir,
        _hooks = hooks,
        _environment = environment ?? Platform.environment,
        _devFallback = devFallback;

  final String? _engineDir;
  final PlatformHooks _hooks;

  /// Injected for hermetic tests; defaults to the real process environment.
  final Map<String, String> _environment;

  /// Tests disable step 5 (the repository's `native/out/...` directory).
  final bool _devFallback;

  String? _llamaPath;
  String? _rpcPath;
  Future<void>? _search;

  bool get _android => Platform.isAndroid;
  bool get _windows => Platform.isWindows;
  bool get _macos => Platform.isMacOS;

  String get _llamaName => _android
      ? 'libllama_server.so'
      : (_windows ? 'llama-server.exe' : 'llama-server');
  String get _rpcName => _android
      ? 'librpc_server.so'
      : (_windows ? 'rpc-server.exe' : 'rpc-server');

  @override
  Future<String?> llamaServerPath() async {
    await _ensureSearched();
    return _llamaPath;
  }

  @override
  Future<String?> rpcServerPath() async {
    await _ensureSearched();
    return _rpcPath;
  }

  @override
  Future<bool> get available async {
    await _ensureSearched();
    return _llamaPath != null && _rpcPath != null;
  }

  /// Environment for engine child processes: makes the shared libraries that
  /// sit next to the binaries discoverable regardless of the working directory.
  Map<String, String> processEnvironment(String binDir) =>
      engineProcessEnvironment(binDir, environment: _environment);

  Future<void> _ensureSearched() => _search ??= _searchNow();

  Future<void> _searchNow() async {
    for (final dir in await _candidateDirs()) {
      final llama = File('$dir/$_llamaName');
      final rpc = File('$dir/$_rpcName');
      if (await _isUsable(llama) && await _isUsable(rpc)) {
        _llamaPath = llama.absolute.path;
        _rpcPath = rpc.absolute.path;
        return;
      }
    }
  }

  Future<List<String>> _candidateDirs() async {
    final dirs = <String>[];

    void add(String? dir) {
      if (dir == null || dir.trim().isEmpty) return;
      final normalized = dir.trim();
      if (!dirs.contains(normalized)) dirs.add(normalized);
    }

    add(_environment['LLMMBC_ENGINE_DIR']);
    add(_engineDir);

    if (_android) {
      try {
        add(await _hooks.nativeLibraryDir?.call());
      } catch (_) {
        // The platform hook is optional and must never break engine discovery.
      }
    }

    if (!_android) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      add('$exeDir/engine');
      add('$exeDir/../engine');
    }

    if (_devFallback) {
      final repoRoot = _repoRoot();
      if (repoRoot != null) {
        add('$repoRoot/native/out/${_platformTag()}');
      }
    }
    return dirs;
  }

  Future<bool> _isUsable(File file) async {
    try {
      if (!await file.exists()) return false;
      if (_windows) return true;
      final mode = (await file.stat()).mode;
      // Any execute bit (owner/group/other) is enough; Android .so files are 0755.
      return mode & 0x49 != 0;
    } on FileSystemException {
      return false;
    }
  }

  /// Platforms whose prebuilt engine directory can be used directly.
  String _platformTag() {
    final os = _android
        ? 'android'
        : _windows
            ? 'windows'
            : _macos
                ? 'macos'
                : 'linux';
    return '$os-${_archTag()}';
  }

  String _archTag() {
    final abi = Abi.current();
    if (abi == Abi.linuxX64 ||
        abi == Abi.macosX64 ||
        abi == Abi.windowsX64 ||
        abi == Abi.androidX64) {
      return 'x64';
    }
    if (abi == Abi.linuxArm64 ||
        abi == Abi.macosArm64 ||
        abi == Abi.windowsArm64 ||
        abi == Abi.androidArm64) {
      return 'arm64';
    }
    return abi.toString().toLowerCase();
  }

  /// Walks up from the current directory (and the executable) looking for the
  /// repository root that owns `native/`.
  String? _repoRoot() {
    final starts = <String>{
      Directory.current.absolute.path,
      File(Platform.resolvedExecutable).parent.absolute.path,
    };
    for (final start in starts) {
      var dir = Directory(start);
      for (var i = 0; i < 8; i++) {
        if (File('${dir.path}/native/LLAMA_CPP_VERSION').existsSync() ||
            Directory('${dir.path}/native/out').existsSync()) {
          return dir.path;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }
}
