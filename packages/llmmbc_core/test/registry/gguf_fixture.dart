import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds small, valid GGUF (v2/v3) files in memory for tests: header + KV metadata + tensor
/// infos + a zero-filled stub data section. The reader never inspects tensor data.
class GgufFixture {
  GgufFixture({this.version = 3}) : assert(version == 2 || version == 3);

  final int version;
  final BytesBuilder _kv = BytesBuilder();
  final BytesBuilder _tensorInfo = BytesBuilder();
  final BytesBuilder _data = BytesBuilder();
  int _kvCount = 0;
  int _tensorCount = 0;
  int _offset = 0;

  static Uint8List _u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _u64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _stringBytes(String value) {
    final encoded = utf8.encode(value);
    final out = BytesBuilder();
    out.add(_u64(encoded.length));
    out.add(encoded);
    return out.takeBytes();
  }

  void _key(String key) {
    _kvCount++;
    _kv.add(_stringBytes(key));
  }

  void kvString(String key, String value) {
    _key(key);
    _kv.add(_u32(8));
    _kv.add(_stringBytes(value));
  }

  void kvUint32(String key, int value) {
    _key(key);
    _kv.add(_u32(4));
    _kv.add(_u32(value));
  }

  void kvInt32(String key, int value) {
    _key(key);
    _kv.add(_u32(5));
    final data = ByteData(4)..setInt32(0, value, Endian.little);
    _kv.add(data.buffer.asUint8List());
  }

  void kvUint64(String key, int value) {
    _key(key);
    _kv.add(_u32(10));
    _kv.add(_u64(value));
  }

  void kvFloat32(String key, double value) {
    _key(key);
    _kv.add(_u32(6));
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    _kv.add(data.buffer.asUint8List());
  }

  void kvBool(String key, bool value) {
    _key(key);
    _kv.add(_u32(7));
    _kv.add(Uint8List.fromList([value ? 1 : 0]));
  }

  void kvStringArray(String key, List<String> values) {
    _key(key);
    _kv.add(_u32(9));
    _kv.add(_u32(8));
    _kv.add(_u64(values.length));
    for (final value in values) {
      _kv.add(_stringBytes(value));
    }
  }

  void kvInt32Array(String key, List<int> values) {
    _key(key);
    _kv.add(_u32(9));
    _kv.add(_u32(5));
    _kv.add(_u64(values.length));
    for (final value in values) {
      final data = ByteData(4)..setInt32(0, value, Endian.little);
      _kv.add(data.buffer.asUint8List());
    }
  }

  /// Appends a tensor info entry plus [dataBytes] of zeroed tensor payload.
  void tensor(String name, List<int> dimensions, int type, int dataBytes) {
    _tensorInfo.add(_stringBytes(name));
    _tensorInfo.add(_u32(dimensions.length));
    for (final dimension in dimensions) {
      _tensorInfo.add(_u64(dimension));
    }
    _tensorInfo.add(_u32(type));
    _tensorInfo.add(_u64(_offset));
    _offset += dataBytes;
    _data.add(Uint8List(dataBytes));
    _tensorCount++;
  }

  Uint8List build() {
    final header = BytesBuilder();
    header.add(const [0x47, 0x47, 0x55, 0x46]); // "GGUF"
    header.add(_u32(version));
    header.add(_u64(_tensorCount));
    header.add(_u64(_kvCount));
    header.add(_kv.takeBytes());
    header.add(_tensorInfo.takeBytes());
    final headerBytes = header.takeBytes();
    final padding = (32 - headerBytes.length % 32) % 32;
    final out = BytesBuilder();
    out.add(headerBytes);
    out.add(Uint8List(padding));
    out.add(_data.takeBytes());
    return out.takeBytes();
  }

  Future<File> writeTo(Directory directory, String name) async {
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(build(), flush: true);
    return file;
  }
}

/// A representative Qwen3-MoE-shaped GGUF file (small dimensions, valid block sizes).
///
/// Tensor sizes:
/// * `blk.0.ffn_gate_exps.weight` [64, 8, 2] Q4_K -> 576 bytes
/// * `blk.0.ffn_up_exps.weight`   [64, 8, 2] Q4_K -> 576 bytes
/// * `blk.0.attn_q.weight`        [64, 64]  F16  -> 8192 bytes
/// * `output.weight`              [64, 64]  Q6_K -> 3360 bytes
GgufFixture moeFixture() => GgufFixture()
  ..kvString('general.architecture', 'qwen3moe')
  ..kvUint32('general.file_type', 17)
  ..kvString('general.name', 'Qwen3MoE test')
  ..kvUint32('qwen3moe.block_count', 4)
  ..kvUint32('qwen3moe.expert_count', 8)
  ..kvUint32('qwen3moe.expert_used_count', 2)
  ..kvUint32('qwen3moe.context_length', 32768)
  ..kvUint32('qwen3moe.embedding_length', 64)
  ..kvString('tokenizer.ggml.model', 'gpt2')
  ..kvStringArray('tokenizer.ggml.tokens', ['<s>', '</s>', 'hello', 'world'])
  ..kvInt32Array('qwen3moe.attention.head_count', [4, 4, 4, 4])
  ..tensor('blk.0.ffn_gate_exps.weight', [64, 8, 2], 12, 576)
  ..tensor('blk.0.ffn_up_exps.weight', [64, 8, 2], 12, 576)
  ..tensor('blk.0.attn_q.weight', [64, 64], 1, 8192)
  ..tensor('output.weight', [64, 64], 14, 3360);

/// A dense GGUF with a single F32 tensor, useful for store tests that do not care about MoE.
GgufFixture denseFixture({String architecture = 'qwen3', int blockCount = 28}) => GgufFixture()
  ..kvString('general.architecture', architecture)
  ..kvUint32('general.file_type', 15)
  ..kvUint32('$architecture.block_count', blockCount)
  ..kvUint32('$architecture.context_length', 40960)
  ..kvUint32('$architecture.embedding_length', 1024)
  ..tensor('token_embd.weight', [64, 64], 0, 64 * 64 * 4);
