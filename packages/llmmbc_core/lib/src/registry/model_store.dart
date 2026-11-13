// STUB – owned by core-data. Replace the body; keep the class name and constructor.
import '../interfaces.dart';
import '../models.dart';
import 'gguf.dart';

class FileModelStore implements ModelStore {
  /// [dataDir] is NodeSettings.dataDir; models live in `<dataDir>/models`.
  /// [registry] defaults to kOllamaRegistry (overridable for tests / mirrors).
  FileModelStore(String dataDir, {GgufInspector inspector = const GgufReader(), String? registry});

  @override
  String get modelsDir => throw UnimplementedError();
  @override
  Future<List<LocalModel>> list() => throw UnimplementedError();
  @override
  Future<LocalModel?> find(ModelRef ref) => throw UnimplementedError();
  @override
  Stream<DownloadProgress> pull(ModelRef ref) => throw UnimplementedError();
  @override
  Future<void> cancel(ModelRef ref) => throw UnimplementedError();
  @override
  Future<void> delete(ModelRef ref) => throw UnimplementedError();
  @override
  List<CatalogEntry> catalog() => throw UnimplementedError();
  @override
  Future<int> remoteSize(ModelRef ref) => throw UnimplementedError();
}
