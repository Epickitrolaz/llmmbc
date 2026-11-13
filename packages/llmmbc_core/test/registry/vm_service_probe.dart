// Probe for issue #68: terminal pull events must not depend on hash-isolate exit timing.
//
// Run it *with* a VM service attached for the regression:
//   dart run --observe test/registry/vm_service_probe.dart cancel
//   dart run --observe test/registry/vm_service_probe.dart drop
//
// Prints one `RESULT scenario=<name> terminal=<state> ms=<elapsed> ...` line. A pull that
// never reaches a terminal state prints `RESULT ... terminal=none` after a timeout and exits
// non-zero, which is what the pre-fix code does under `--observe`.
import 'dart:async';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';

const int _blobBytes = 6 << 20;
const int _chunkBytes = 64 << 10;

Future<void> main(List<String> args) async {
  final scenario = args.isEmpty ? 'cancel' : args.first;
  final payload = List<int>.filled(_blobBytes, 7);
  final digest = 'sha256:${'0' * 64}'; // the pull is stopped before verification
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    if (request.uri.pathSegments.length > 3 && request.uri.pathSegments[3] == 'manifests') {
      response.write('{"schemaVersion":2,"layers":[{"mediaType":'
          '"application/vnd.ollama.image.model","digest":"$digest",'
          '"size":${payload.length}}]}');
      await response.close();
      return;
    }
    response.contentLength = payload.length;
    var sent = 0;
    try {
      while (sent < payload.length) {
        final end = sent + _chunkBytes > payload.length ? payload.length : sent + _chunkBytes;
        response.add(payload.sublist(sent, end));
        await response.flush();
        sent = end;
        // Slow enough that a cancel/drop reliably lands mid-body.
        await Future<void>.delayed(const Duration(milliseconds: 4));
        if (scenario == 'drop' && sent >= (1 << 20)) {
          // Mid-body failure: close the connection short of the declared content length.
          await response.close();
          return;
        }
      }
      await response.close();
    } catch (_) {
      // Client went away.
    }
  });

  final dir = await Directory.systemTemp.createTemp('llmmbc_vmprobe_');
  final store = FileModelStore(dir.path, registry: 'http://127.0.0.1:${server.port}');
  final ref = ModelRef.parse('m:latest');
  final watch = Stopwatch()..start();
  DownloadState? terminal;
  String? error;
  var cancelRequested = false;
  try {
    await for (final progress in store.pull(ref)) {
      if (scenario == 'cancel' &&
          !cancelRequested &&
          progress.state == DownloadState.downloading &&
          progress.receivedBytes > (1 << 20)) {
        cancelRequested = true;
        unawaited(store.cancel(ref).then((_) {}));
      }
      if (progress.state == DownloadState.cancelled ||
          progress.state == DownloadState.failed ||
          progress.state == DownloadState.done) {
        terminal = progress.state;
        error = progress.error;
        break;
      }
    }
  } catch (e) {
    error ??= '$e';
  }
  watch.stop();
  stdout.writeln('RESULT scenario=$scenario terminal=${terminal?.name ?? 'none'} '
      'ms=${watch.elapsedMilliseconds} error=${error ?? ''}');
  await server.close(force: true);
  if (await dir.exists()) await dir.delete(recursive: true);
  exit(terminal == null ? 1 : 0);
}
