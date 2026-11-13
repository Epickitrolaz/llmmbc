import 'dart:io';
import 'dart:typed_data';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

import 'gguf_fixture.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llmmbc_gguf_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('reads GGUF v3 metadata and tensor sizes without touching tensor data', () async {
    final file = await moeFixture().writeTo(tempDir, 'moe.gguf');
    final metadata = await const GgufReader().read(file.path);

    expect(metadata.architecture, 'qwen3moe');
    expect(metadata.blockCount, 4);
    expect(metadata.expertCount, 8);
    expect(metadata.expertUsedCount, 2);
    expect(metadata.contextLength, 32768);
    expect(metadata.embeddingLength, 64);
    expect(metadata.fileType, 17);
    expect(metadata.isMoe, isTrue);
    // Two ffn_*_exps tensors of [64,8,2] Q4_K = 4 blocks * 144 bytes each.
    expect(metadata.expertTensorBytes, 2 * 576);
    // 1152 (experts) + 8192 (F16 attn) + 3360 (Q6_K output).
    expect(metadata.totalTensorBytes, 12704);
  });

  test('reads GGUF v2 headers', () async {
    final file = await (GgufFixture(version: 2)..kvString('general.architecture', 'llama')
          ..kvUint32('llama.block_count', 12)
          ..tensor('token_embd.weight', [16], 0, 64))
        .writeTo(tempDir, 'v2.gguf');
    final metadata = await const GgufReader().read(file.path);
    expect(metadata.architecture, 'llama');
    expect(metadata.blockCount, 12);
    expect(metadata.totalTensorBytes, 64);
  });

  test('dense models report no experts', () async {
    final file = await denseFixture().writeTo(tempDir, 'dense.gguf');
    final metadata = await const GgufReader().read(file.path);
    expect(metadata.architecture, 'qwen3');
    expect(metadata.blockCount, 28);
    expect(metadata.expertCount, 0);
    expect(metadata.expertUsedCount, 0);
    expect(metadata.isMoe, isFalse);
    expect(metadata.expertTensorBytes, 0);
    expect(metadata.totalTensorBytes, 64 * 64 * 4);
  });

  test('estimates unknown tensor types from the next offset / file end', () async {
    final file = await (GgufFixture()
          ..kvString('general.architecture', 'llama')
          ..kvUint32('llama.block_count', 1)
          ..tensor('a.weight', [32], 0, 128)
          ..tensor('mystery.weight', [32], 250, 100))
        .writeTo(tempDir, 'unknown.gguf');
    final metadata = await const GgufReader().read(file.path);
    // F32 [32] = 128 bytes, unknown = 100 bytes (data section ends there).
    expect(metadata.totalTensorBytes, 228);
    expect(metadata.expertTensorBytes, 0);
  });

  test('header-only files are read without touching the (missing) data section', () async {
    final file = await (GgufFixture()
          ..kvString('general.architecture', 'llama')
          ..tensor('token_embd.weight', [64, 64], 0, 0))
        .writeTo(tempDir, 'truncated.gguf');
    final metadata = await const GgufReader().read(file.path);
    expect(metadata.totalTensorBytes, 64 * 64 * 4);
  });

  test('metadata arrays are skipped and do not corrupt later keys', () async {
    final file = await (GgufFixture()
          ..kvStringArray('tokenizer.ggml.tokens',
              List.generate(1000, (i) => 'token$i'))
          ..kvInt32Array('llama.rope_sections', [16, 16, 16, 16])
          ..kvString('general.architecture', 'llama')
          ..kvUint32('llama.block_count', 7))
        .writeTo(tempDir, 'arrays.gguf');
    final metadata = await const GgufReader().read(file.path);
    expect(metadata.architecture, 'llama');
    expect(metadata.blockCount, 7);
  });

  test('rejects files that are not GGUF', () async {
    final file = File('${tempDir.path}/bad.bin');
    await file.writeAsBytes(Uint8List.fromList([0x4e, 0x4f, 0x50, 0x45]));
    await expectLater(const GgufReader().read(file.path), throwsA(isA<FormatException>()));
  });

  test('rejects unsupported GGUF versions', () async {
    final file = File('${tempDir.path}/v99.gguf');
    final bytes = BytesBuilder()
      ..add(const [0x47, 0x47, 0x55, 0x46])
      ..add((ByteData(4)..setUint32(0, 99, Endian.little)).buffer.asUint8List());
    await file.writeAsBytes(bytes.takeBytes());
    await expectLater(const GgufReader().read(file.path), throwsA(isA<FormatException>()));
  });

  test('missing file throws a FileSystemException', () async {
    await expectLater(
        const GgufReader().read('${tempDir.path}/nope.gguf'),
        throwsA(isA<FileSystemException>()));
  });

  test('ggml block size table covers the required types', () {
    expect(tensorByteSize([4096], 0), 4096 * 4); // F32
    expect(tensorByteSize([4096], 1), 4096 * 2); // F16
    expect(tensorByteSize([4096], 30), 4096 * 2); // BF16
    expect(tensorByteSize([32], 2), 18); // Q4_0
    expect(tensorByteSize([32], 3), 20); // Q4_1
    expect(tensorByteSize([32], 6), 22); // Q5_0
    expect(tensorByteSize([32], 7), 24); // Q5_1
    expect(tensorByteSize([32], 8), 34); // Q8_0
    expect(tensorByteSize([256], 10), 84); // Q2_K
    expect(tensorByteSize([256], 11), 110); // Q3_K
    expect(tensorByteSize([256], 12), 144); // Q4_K
    expect(tensorByteSize([256], 13), 176); // Q5_K
    expect(tensorByteSize([256], 14), 210); // Q6_K
    expect(tensorByteSize([256], 15), 292); // Q8_K
    expect(tensorByteSize([256], 16), 66); // IQ2_XXS
    expect(tensorByteSize([256], 19), 50); // IQ1_S
    expect(tensorByteSize([256], 23), 136); // IQ4_XS
    expect(tensorByteSize([32], 39), 17); // MXFP4
    expect(tensorByteSize([32], 999), isNull);
  });
}
