// STUB – owned by core-net. Replace the body; keep the class name and factory signature.
import '../interfaces.dart';

abstract class LocalNodeService implements NodeService {
  /// Loads/creates settings at [settingsPath] (JSON of NodeSettings), defaulting dataDir to
  /// [defaultDataDir]. Wires LocalHardwareProbe, FileModelStore, LanDiscovery, HttpNodeClient,
  /// DefaultEngineLocator, LlamaCppEngine, DefaultClusterPlanner and NodeApiServer.
  static Future<LocalNodeService> create({
    required String settingsPath,
    required String defaultDataDir,
    PlatformHooks platform = const PlatformHooks(),
  }) =>
      throw UnimplementedError();
}
