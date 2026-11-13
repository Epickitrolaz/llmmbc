// STUB – owned by core-data. Replace the body; keep the class name and constructor.
import '../interfaces.dart';
import '../models.dart';

class LocalHardwareProbe implements HardwareProbe {
  final PlatformHooks hooks;
  LocalHardwareProbe({this.hooks = const PlatformHooks()});

  @override
  Future<HardwareProfile> scan() => throw UnimplementedError();

  @override
  Future<HardwareProfile> refresh(HardwareProfile previous) => throw UnimplementedError();
}
