import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('llmmbc_engine_locator_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> writeBinary(String dir, String name,
      {bool executable = true}) async {
    final file = File('$dir/$name');
    await file.writeAsString('#!/bin/sh\nexit 0\n');
    if (!Platform.isWindows) {
      await Process.run('chmod', [executable ? '+x' : '-x', file.path]);
    }
  }

  test('finds both binaries in an explicit engine directory', () async {
    await writeBinary(tmp.path, 'llama-server');
    await writeBinary(tmp.path, 'rpc-server');
    final locator = DefaultEngineLocator(
        engineDir: tmp.path, environment: const {}, devFallback: false);

    expect(await locator.available, isTrue);
    expect(await locator.llamaServerPath(), '${tmp.path}/llama-server');
    expect(await locator.rpcServerPath(), '${tmp.path}/rpc-server');
  });

  test('unavailable when one binary is missing', () async {
    await writeBinary(tmp.path, 'llama-server');
    final locator = DefaultEngineLocator(
        engineDir: tmp.path, environment: const {}, devFallback: false);

    expect(await locator.available, isFalse);
    expect(await locator.llamaServerPath(), isNull);
    expect(await locator.rpcServerPath(), isNull);
  });

  test('unavailable when a binary is not executable', () async {
    await writeBinary(tmp.path, 'llama-server');
    await writeBinary(tmp.path, 'rpc-server', executable: false);
    final locator = DefaultEngineLocator(
        engineDir: tmp.path, environment: const {}, devFallback: false);

    expect(await locator.available, isFalse);
  });

  test('unavailable when the directory does not exist', () async {
    final locator = DefaultEngineLocator(
        engineDir: '${tmp.path}/missing',
        environment: const {},
        devFallback: false);
    expect(await locator.available, isFalse);
  });

  test('LLMMBC_ENGINE_DIR wins over engineDir', () async {
    final envDir = Directory('${tmp.path}/env')..createSync();
    final settingsDir = Directory('${tmp.path}/settings')..createSync();
    await writeBinary(envDir.path, 'llama-server');
    await writeBinary(envDir.path, 'rpc-server');
    await writeBinary(settingsDir.path, 'llama-server');
    await writeBinary(settingsDir.path, 'rpc-server');

    final locator = DefaultEngineLocator(
      engineDir: settingsDir.path,
      environment: {'LLMMBC_ENGINE_DIR': envDir.path},
      devFallback: false,
    );
    expect(await locator.llamaServerPath(), '${envDir.path}/llama-server');
    expect(await locator.rpcServerPath(), '${envDir.path}/rpc-server');
  });

  test('ambient LLMMBC_ENGINE_DIR is ignored when the environment is injected',
      () async {
    await writeBinary(tmp.path, 'llama-server');
    await writeBinary(tmp.path, 'rpc-server');
    final locator = DefaultEngineLocator(
        engineDir: tmp.path, environment: const {}, devFallback: false);
    expect(await locator.available, isTrue);
    expect(await locator.llamaServerPath(), '${tmp.path}/llama-server');
  });

  test('processEnvironment prepends the binary directory to loader paths', () {
    final locator =
        DefaultEngineLocator(environment: const {'PATH': '/usr/bin'});
    final env = locator.processEnvironment('/opt/llmmbc/engine');
    expect(env['PATH'],
        '/opt/llmmbc/engine${Platform.isWindows ? ';' : ':'}/usr/bin');
    if (Platform.isLinux || Platform.isAndroid) {
      expect(env['LD_LIBRARY_PATH'], '/opt/llmmbc/engine');
    } else if (Platform.isMacOS) {
      expect(env['DYLD_LIBRARY_PATH'], '/opt/llmmbc/engine');
    }
  });
}
