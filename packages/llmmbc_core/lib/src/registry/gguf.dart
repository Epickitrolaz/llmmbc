// GGUF header/metadata reader. Owned by core-data (docs/ARCHITECTURE.md §2.4, §5).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../interfaces.dart';
import '../models.dart';

/// ggml tensor type: elements per block and bytes per block.
///
/// Mirrors `ggml_type_traits` in llama.cpp. Unknown types fall back to an estimate derived
/// from the tensor offsets and the file length (see [GgufReader.read]).
class GgmlTypeInfo {
  final int elements;
  final int bytes;
  const GgmlTypeInfo(this.elements, this.bytes);
}

/// Block layout table for the ggml types llama.cpp can write into GGUF files.
const Map<int, GgmlTypeInfo> kGgmlTypes = {
  0: GgmlTypeInfo(1, 4), // F32
  1: GgmlTypeInfo(1, 2), // F16
  2: GgmlTypeInfo(32, 18), // Q4_0
  3: GgmlTypeInfo(32, 20), // Q4_1
  6: GgmlTypeInfo(32, 22), // Q5_0
  7: GgmlTypeInfo(32, 24), // Q5_1
  8: GgmlTypeInfo(32, 34), // Q8_0
  9: GgmlTypeInfo(32, 36), // Q8_1
  10: GgmlTypeInfo(256, 84), // Q2_K
  11: GgmlTypeInfo(256, 110), // Q3_K
  12: GgmlTypeInfo(256, 144), // Q4_K
  13: GgmlTypeInfo(256, 176), // Q5_K
  14: GgmlTypeInfo(256, 210), // Q6_K
  15: GgmlTypeInfo(256, 292), // Q8_K
  16: GgmlTypeInfo(256, 66), // IQ2_XXS
  17: GgmlTypeInfo(256, 74), // IQ2_XS
  18: GgmlTypeInfo(256, 98), // IQ3_XXS
  19: GgmlTypeInfo(256, 50), // IQ1_S
  20: GgmlTypeInfo(32, 18), // IQ4_NL
  21: GgmlTypeInfo(256, 110), // IQ3_S
  22: GgmlTypeInfo(256, 82), // IQ2_S
  23: GgmlTypeInfo(256, 136), // IQ4_XS
  24: GgmlTypeInfo(1, 1), // I8
  25: GgmlTypeInfo(1, 2), // I16
  26: GgmlTypeInfo(1, 4), // I32
  27: GgmlTypeInfo(1, 8), // I64
  28: GgmlTypeInfo(1, 8), // F64
  29: GgmlTypeInfo(256, 56), // IQ1_M
  30: GgmlTypeInfo(1, 2), // BF16
  34: GgmlTypeInfo(256, 54), // TQ1_0
  35: GgmlTypeInfo(256, 66), // TQ2_0
  39: GgmlTypeInfo(32, 17), // MXFP4
};

/// Tensor entries whose name matches `ffn_.*_exps` are the routed MoE experts.
final RegExp kExpertTensorPattern = RegExp(r'ffn_.*_exps');

/// Absolute byte size of a tensor from its dimensions and ggml type, or null for an
/// unknown type.
int? tensorByteSize(List<int> dimensions, int type) {
  final info = kGgmlTypes[type];
  if (info == null) return null;
  var elements = 1;
  for (final dim in dimensions) {
    if (dim < 0) return null;
    elements *= dim;
  }
  if (elements == 0) return 0;
  final blocks = (elements + info.elements - 1) ~/ info.elements;
  return blocks * info.bytes;
}

/// Reads GGUF v1/v2/v3 headers, KV metadata and tensor infos.
///
/// Only the header region is read: tensor data is never loaded, so the cost of inspecting a
/// multi-gigabyte model is a few small file reads.
class GgufReader implements GgufInspector {
  const GgufReader();

  @override
  Future<GgufMetadata> read(String path) async {
    final file = File(path);
    final raf = await file.open();
    try {
      final length = await raf.length();
      final reader = _ByteReader(raf, length);

      final magic = await reader.take(4);
      if (magic[0] != 0x47 || magic[1] != 0x47 || magic[2] != 0x55 || magic[3] != 0x46) {
        throw const FormatException('not a GGUF file (bad magic)');
      }
      final version = await reader.uint32();
      if (version < 1 || version > 3) {
        throw FormatException('unsupported GGUF version $version');
      }
      final legacy = version == 1;
      final tensorCount = legacy ? await reader.uint32() : await reader.uint64();
      final kvCount = legacy ? await reader.uint32() : await reader.uint64();

      final values = <String, Object>{};
      for (var i = 0; i < kvCount; i++) {
        final key = await reader.string(legacy);
        final type = await reader.uint32();
        final value = await reader.value(type, legacy);
        // Arrays are skipped (returned as null) – only scalar metadata is needed.
        if (value != null) values[key] = value;
      }

      final tensors = <_GgufTensor>[];
      for (var i = 0; i < tensorCount; i++) {
        final name = await reader.string(legacy);
        final rank = await reader.uint32();
        final dims = <int>[];
        for (var d = 0; d < rank; d++) {
          dims.add(legacy ? await reader.uint32() : await reader.uint64());
        }
        final type = await reader.uint32();
        final offset = legacy ? await reader.uint32() : await reader.uint64();
        tensors.add(_GgufTensor(name: name, dimensions: dims, type: type, offset: offset));
      }

      final alignment = _asInt(values['general.alignment']) ?? 32;
      final safeAlignment = alignment <= 0 ? 32 : alignment;
      final headerEnd = reader.position;
      final dataStart = _alignUp(headerEnd, safeAlignment);
      final dataSize = length > dataStart ? length - dataStart : 0;

      return _metadata(values, tensors, dataStart, dataSize);
    } finally {
      await raf.close();
    }
  }

  GgufMetadata _metadata(
      Map<String, Object> values, List<_GgufTensor> tensors, int dataStart, int dataSize) {
    final architecture = values['general.architecture'] as String? ?? '';

    int intValue(String key) => _asInt(values[key]) ?? 0;

    // Estimate sizes for tensors whose type is unknown from the next tensor's offset (all
    // tensors are laid out back-to-back in the data section). The final tensor extends to EOF.
    final sorted = [...tensors]..sort((a, b) => a.offset.compareTo(b.offset));
    var totalTensorBytes = 0;
    var expertTensorBytes = 0;
    for (var i = 0; i < sorted.length; i++) {
      final tensor = sorted[i];
      var size = tensorByteSize(tensor.dimensions, tensor.type);
      if (size == null) {
        final end = i + 1 < sorted.length ? sorted[i + 1].offset : dataSize;
        size = end - tensor.offset;
        if (size < 0) size = 0;
      }
      totalTensorBytes += size;
      if (kExpertTensorPattern.hasMatch(tensor.name)) {
        expertTensorBytes += size;
      }
    }
    // Guard against corrupt/truncated files: never report more data than the file holds.
    if (dataSize > 0 && totalTensorBytes > dataSize) totalTensorBytes = dataSize;
    if (expertTensorBytes > totalTensorBytes) expertTensorBytes = totalTensorBytes;

    return GgufMetadata(
      architecture: architecture,
      blockCount: intValue('$architecture.block_count'),
      expertCount: intValue('$architecture.expert_count'),
      expertUsedCount: intValue('$architecture.expert_used_count'),
      contextLength: intValue('$architecture.context_length'),
      embeddingLength: intValue('$architecture.embedding_length'),
      fileType: _asInt(values['general.file_type']) ?? -1,
      expertTensorBytes: expertTensorBytes,
      totalTensorBytes: totalTensorBytes,
    );
  }
}

int _alignUp(int value, int alignment) {
  final remainder = value % alignment;
  return remainder == 0 ? value : value + (alignment - remainder);
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  return null;
}

class _GgufTensor {
  final String name;
  final List<int> dimensions;
  final int type;
  final int offset;
  const _GgufTensor({
    required this.name,
    required this.dimensions,
    required this.type,
    required this.offset,
  });
}

// GGUF metadata value types.
const int _typeUint8 = 0;
const int _typeInt8 = 1;
const int _typeUint16 = 2;
const int _typeInt16 = 3;
const int _typeUint32 = 4;
const int _typeInt32 = 5;
const int _typeFloat32 = 6;
const int _typeBool = 7;
const int _typeString = 8;
const int _typeArray = 9;
const int _typeUint64 = 10;
const int _typeInt64 = 11;
const int _typeFloat64 = 12;

/// Lexical reader for the header region only. Buffered so that many tiny reads (keys, value
/// types) do not turn into thousands of syscalls.
class _ByteReader {
  _ByteReader(this._raf, this._length);

  static const int _bufferSize = 1 << 16;

  final RandomAccessFile _raf;
  final int _length;
  final Uint8List _buffer = Uint8List(_bufferSize);
  int _bufferStart = 0;
  int _bufferLength = 0;
  int _position = 0;

  /// Absolute file offset of the next unread byte.
  int get position => _bufferStart + _position;

  Future<void> _fill() async {
    final offset = _bufferStart + _bufferLength;
    await _raf.setPosition(offset);
    final read = await _raf.readInto(_buffer, 0, _bufferSize);
    if (read <= 0) throw const FormatException('unexpected end of file');
    _bufferStart = offset;
    _bufferLength = read;
    _position = 0;
  }

  Future<Uint8List> take(int count) async {
    if (count < 0) throw const FormatException('negative read');
    if (count == 0) return Uint8List(0);
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_position >= _bufferLength) {
        await _fill();
      }
      final available = _bufferLength - _position;
      final chunk = (count - written) < available ? (count - written) : available;
      out.setRange(written, written + chunk, _buffer, _position);
      _position += chunk;
      written += chunk;
    }
    return out;
  }

  Future<void> skip(int count) async {
    if (count < 0) throw const FormatException('negative skip');
    var remaining = count;
    while (remaining > 0) {
      if (_position >= _bufferLength) {
        await _fill();
      }
      final available = _bufferLength - _position;
      final chunk = remaining < available ? remaining : available;
      _position += chunk;
      remaining -= chunk;
    }
  }

  Future<int> uint32() async {
    final bytes = await take(4);
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  Future<int> uint64() async {
    final bytes = await take(8);
    return ByteData.sublistView(bytes).getUint64(0, Endian.little);
  }

  Future<String> string(bool legacy) async {
    final length = legacy ? await uint32() : await uint64();
    if (length < 0 || position + length > _length) {
      throw const FormatException('GGUF string exceeds file length');
    }
    if (length == 0) return '';
    final bytes = await take(length);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Object?> value(int type, bool legacy) async {
    switch (type) {
      case _typeUint8:
        return (await take(1))[0];
      case _typeInt8:
        return ByteData.sublistView(await take(1)).getInt8(0);
      case _typeUint16:
        return ByteData.sublistView(await take(2)).getUint16(0, Endian.little);
      case _typeInt16:
        return ByteData.sublistView(await take(2)).getInt16(0, Endian.little);
      case _typeUint32:
        return uint32();
      case _typeInt32:
        return ByteData.sublistView(await take(4)).getInt32(0, Endian.little);
      case _typeFloat32:
        return ByteData.sublistView(await take(4)).getFloat32(0, Endian.little);
      case _typeBool:
        return (await take(1))[0] != 0;
      case _typeString:
        return string(legacy);
      case _typeArray:
        final itemType = await uint32();
        final count = legacy ? await uint32() : await uint64();
        if (count < 0) throw const FormatException('negative GGUF array length');
        // Metadata arrays (tokenizer vocab, merges, ...) are large and irrelevant here.
        for (var i = 0; i < count; i++) {
          await _skipValue(itemType, legacy);
        }
        return null;
      case _typeUint64:
        return uint64();
      case _typeInt64:
        return ByteData.sublistView(await take(8)).getInt64(0, Endian.little);
      case _typeFloat64:
        return ByteData.sublistView(await take(8)).getFloat64(0, Endian.little);
      default:
        throw FormatException('unsupported GGUF metadata value type $type');
    }
  }

  Future<void> _skipValue(int type, bool legacy) async {
    switch (type) {
      case _typeUint8:
      case _typeInt8:
      case _typeBool:
        await skip(1);
      case _typeUint16:
      case _typeInt16:
        await skip(2);
      case _typeUint32:
      case _typeInt32:
      case _typeFloat32:
        await skip(4);
      case _typeUint64:
      case _typeInt64:
      case _typeFloat64:
        await skip(8);
      case _typeString:
        final length = legacy ? await uint32() : await uint64();
        await skip(length);
      case _typeArray:
        final itemType = await uint32();
        final count = legacy ? await uint32() : await uint64();
        for (var i = 0; i < count; i++) {
          await _skipValue(itemType, legacy);
        }
      default:
        throw FormatException('unsupported GGUF metadata value type $type');
    }
  }
}
