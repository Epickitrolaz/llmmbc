// Standalone loopback registry for the large-pull tests. Runs in its own OS process so the
// 1 GiB body never counts against the pulling process's RSS.
//
// Usage: dart test/registry/large_blob_server.dart
// Prints `PORT=<port>` once it is listening, then serves:
//   GET /v2/library/huge/manifests/1b
//   GET /v2/library/huge/blobs/sha256:<digest>   (Range supported)
//
// Only dart:io is imported so it can be launched with `dart <file>` from a test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 1 GiB of [block] repeated: kept in sync with `largeBlobDigest` below.
const int blobBytes = 1024 << 20;

/// sha256 of the 1 GiB content described by [buildBlock]. Compute again if the pattern
/// changes (see the comment in `large_pull_test.dart`).
const String largeBlobDigest =
    'b5a8a86aa6f08b9be0ecc2a349af9acdd185eded82d909b5f3e512183d741eed';

Uint8List buildBlock() {
  final block = Uint8List(1 << 20);
  var state = 0x9E3779B9;
  for (var i = 0; i < block.length; i++) {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    block[i] = (state >> 24) & 0xFF;
  }
  return block;
}

Future<void> main() async {
  final block = buildBlock();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  stdout.writeln('PORT=${server.port}');
  await stdout.flush();
  await for (final request in server) {
    unawaited(_handle(request, block));
  }
}

Future<void> _handle(HttpRequest request, Uint8List block) async {
  final response = request.response;
  try {
    final segments = request.uri.pathSegments;
    if (segments.length == 5 &&
        segments[0] == 'v2' &&
        segments[3] == 'manifests' &&
        segments[1] == 'library' &&
        segments[2] == 'huge' &&
        segments[4] == '1b') {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({
        'schemaVersion': 2,
        'mediaType': 'application/vnd.docker.distribution.manifest.v2+json',
        'layers': [
          {
            'mediaType': 'application/vnd.ollama.image.model',
            'digest': 'sha256:$largeBlobDigest',
            'size': blobBytes,
          },
        ],
      }));
      await response.close();
      return;
    }

    if (segments.length == 5 &&
        segments[0] == 'v2' &&
        segments[3] == 'blobs' &&
        segments[4] == 'sha256:$largeBlobDigest') {
      var start = 0;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.startsWith('bytes=')) {
        start = int.tryParse(range.substring('bytes='.length).split('-').first) ?? 0;
        if (start >= blobBytes) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await response.close();
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$blobBytes-1/$blobBytes');
      }
      response.headers.contentType = ContentType.binary;
      response.headers.contentLength = blobBytes - start;
      // Feed the body as fast as the socket accepts it: the client's back-pressure is what
      // is under test, so no artificial pacing here. Content is `block` repeated, so a Range
      // resume may start in the middle of a block.
      var offset = start;
      final misaligned = offset % block.length;
      if (misaligned != 0) {
        final count = block.length - misaligned;
        response.add(Uint8List.sublistView(block, misaligned, misaligned + count));
        offset += count;
        await response.flush();
      }
      while (offset < blobBytes) {
        final remaining = blobBytes - offset;
        if (remaining >= block.length) {
          response.add(block);
          offset += block.length;
        } else {
          response.add(Uint8List.sublistView(block, 0, remaining));
          offset += remaining;
        }
        await response.flush();
      }
      await response.close();
      return;
    }

    response.statusCode = HttpStatus.notFound;
    await response.close();
  } catch (_) {
    // The client went away (cancel/back-pressure test): nothing to clean up.
    try {
      await response.close();
    } catch (_) {}
  }
}
