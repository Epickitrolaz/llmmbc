// STUB – owned by engine. Replace the body; keep the class name and constructor.
import '../interfaces.dart';

class DefaultEngineLocator implements EngineLocator {
  DefaultEngineLocator({String? engineDir, PlatformHooks hooks = const PlatformHooks()});

  @override
  Future<String?> llamaServerPath() => throw UnimplementedError();
  @override
  Future<String?> rpcServerPath() => throw UnimplementedError();
  @override
  Future<bool> get available => throw UnimplementedError();
}
