import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Minimal in-process Ollama registry: manifests, blobs, HTTP Range support and
/// deliberate failure/slow-down knobs for the model store tests.
class MockRegistry {
  HttpServer? _server;

  /// Blob content by sha256 hex.
  final Map<String, Uint8List> blobs = {};

  /// Manifest JSON by `namespace/name/tag`.
  final Map<String, Map<String, dynamic>> manifests = {};

  int manifestRequests = 0;
  int blobRequests = 0;
  final Map<String, int> blobRequestCounts = {};
  final List<String?> rangeHeaders = [];

  Duration chunkDelay = Duration.zero;
  int chunkSize = 64 * 1024;
  bool supportsRange = true;
  bool corruptBlobs = false;

  /// Accept the request but never send response headers (simulates a hung registry).
  bool stallManifestResponses = false;

  /// Send blob headers but never send the body (simulates a stalled download).
  bool stallBlobBody = false;

  /// Answer blob requests with HTTP 500 and stall the error body (issue #26).
  bool stallErrorBody = false;

  /// Responses intentionally left open by the stall knobs (closed by [close]).
  final List<HttpResponse> heldResponses = [];

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> close() async {
    for (final response in heldResponses) {
      try {
        await response.close();
      } catch (_) {
        // The client may already have gone away.
      }
    }
    heldResponses.clear();
    await _server?.close(force: true);
  }

  /// Registers [layers] (mediaType -> bytes) and a manifest for the ref. Returns the
  /// model-layer digest hex.
  String addModel(String namespace, String name, String tag, Map<String, Uint8List> layers) {
    final entries = <Map<String, dynamic>>[];
    String? modelHex;
    for (final entry in layers.entries) {
      final bytes = entry.value;
      final hex = sha256.convert(bytes).toString();
      blobs[hex] = bytes;
      entries.add({'mediaType': entry.key, 'digest': 'sha256:$hex', 'size': bytes.length});
      if (entry.key == 'application/vnd.ollama.image.model') modelHex = hex;
    }
    manifests['$namespace/$name/$tag'] = {
      'schemaVersion': 2,
      'mediaType': 'application/vnd.docker.distribution.manifest.v2+json',
      'layers': entries,
    };
    return modelHex ?? '';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      // /v2/<ns>/<name>/manifests/<tag>
      if (segments.length == 5 &&
          segments[0] == 'v2' &&
          segments[3] == 'manifests') {
        manifestRequests++;
        final key = '${segments[1]}/${segments[2]}/${segments[4]}';
        if (stallManifestResponses) {
          heldResponses.add(response);
          return;
        }
        final json = manifests[key];
        if (json == null) {
          response.statusCode = HttpStatus.notFound;
          response.headers.contentType = ContentType.json;
          response.write('{"errors":[{"code":"MANIFEST_UNKNOWN"}]}');
        } else {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(json));
        }
        await response.close();
        return;
      }

      // /v2/<ns>/<name>/blobs/sha256:<hex>
      if (segments.length == 5 &&
          segments[0] == 'v2' &&
          segments[3] == 'blobs' &&
          segments[4].startsWith('sha256:')) {
        blobRequests++;
        final hex = segments[4].substring('sha256:'.length);
        final range = request.headers.value(HttpHeaders.rangeHeader);
        rangeHeaders.add(range);
        blobRequestCounts[hex] = (blobRequestCounts[hex] ?? 0) + 1;

        if (stallErrorBody) {
          response.statusCode = HttpStatus.internalServerError;
          response.headers.contentType = ContentType.json;
          response.headers.contentLength = 1000;
          response.add(utf8.encode('{"errors":['));
          await response.flush();
          heldResponses.add(response);
          return;
        }

        final source = blobs[hex];
        if (source == null) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        var data = source;
        if (corruptBlobs) {
          data = Uint8List.fromList(source);
          if (data.isNotEmpty) data[0] = data[0] ^ 0xff;
        }

        var start = 0;
        if (supportsRange && range != null && range.startsWith('bytes=')) {
          start = int.tryParse(range.substring('bytes='.length).split('-').first) ?? 0;
          if (start >= data.length) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await response.close();
            return;
          }
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader,
              'bytes $start-${data.length - 1}/${data.length}');
        } else {
          response.statusCode = HttpStatus.ok;
        }
        response.headers.contentType = ContentType.binary;
        response.headers.contentLength = data.length - start;
        if (stallBlobBody) {
          // Send a small prefix so the headers reach the client, then stall mid-body.
          final end = min(start + 16, data.length);
          response.add(data.sublist(start, end));
          await response.flush();
          heldResponses.add(response);
          return;
        }
        for (var offset = start; offset < data.length; offset += chunkSize) {
          if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
          response.add(data.sublist(offset, min(offset + chunkSize, data.length)));
          await response.flush();
        }
        await response.close();
        return;
      }

      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (_) {
      // Client cancelled mid-stream: the socket is already gone.
      try {
        await response.close();
      } catch (_) {
        // Ignore.
      }
    }
  }
}
