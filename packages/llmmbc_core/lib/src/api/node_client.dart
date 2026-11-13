// core-net: HTTP client for another node's API (docs/ARCHITECTURE.md §3).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';
import 'sse.dart';

/// Chat routing marker (`docs/ARCHITECTURE.md` §3).
const String kHeaderChatRoute = 'X-LLMMBC-Route';

/// Value of [kHeaderChatRoute] that asks the receiver to serve as coordinator.
const String kRouteCoordinator = 'coordinator';

/// Chat requests must tolerate a cold model load on the coordinator before the
/// first SSE byte; ≥ 10 minutes and separate from [HttpNodeClient.timeout].
const Duration kChatFirstByteTimeout = Duration(minutes: 10);

/// Maximum silence between two SSE chunks of an active chat stream.
const Duration kChatIdleTimeout = Duration(minutes: 2);

/// [NodeClient] capability to add [kHeaderChatRoute] to a forwarded chat.
abstract class ChatRouteClient {
  Stream<ChatDelta> chat(
    Uri base,
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
    bool asCoordinator,
  });
}

/// `NodeClient` implementation over `package:http`.
class HttpNodeClient implements NodeClient, ChatRouteClient {
  final Duration timeout;
  final Duration chatTimeout;
  final Duration chatIdleTimeout;
  final http.Client _http;

  HttpNodeClient({
    this.timeout = const Duration(seconds: 5),
    this.chatTimeout = kChatFirstByteTimeout,
    this.chatIdleTimeout = kChatIdleTimeout,
    http.Client? client,
  }) : _http = client ??
            io_client.IOClient(HttpClient()..connectionTimeout = timeout);

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json'
  };

  Uri _uri(Uri base, String path) => base.resolve(path);

  Map<String, String> _headers(Uri base) => {
        ..._jsonHeaders,
        kHeaderProtocol: '$kProtocolVersion',
      };

  LlmmbcException _error(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map;
        return LlmmbcException(
          err['code'] as String? ?? 'internal',
          err['message'] as String? ?? body,
          httpStatus: status,
        );
      }
    } on FormatException {
      // fall through
    }
    return LlmmbcException('internal', body.isEmpty ? 'HTTP $status' : body,
        httpStatus: status);
  }

  Future<http.Response> _get(Uri base, String path, {Duration? timeout}) =>
      _http
          .get(_uri(base, path), headers: _headers(base))
          .timeout(timeout ?? this.timeout);

  Future<http.Response> _post(Uri base, String path, Object body,
          {Duration? timeout}) =>
      _http
          .post(_uri(base, path),
              headers: _headers(base), body: jsonEncode(body))
          .timeout(timeout ?? this.timeout);

  @override
  Future<NodeInfo> info(Uri base, {Duration? timeout}) async {
    final res = await _get(base, '/v1/node', timeout: timeout);
    if (res.statusCode != 200) throw _error(res.statusCode, res.body);
    final info =
        NodeInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    return info.host.isEmpty ? info.copyWith(host: base.host) : info;
  }

  @override
  Future<List<NodeInfo>> peers(Uri base) async {
    final res = await _get(base, '/v1/peers');
    if (res.statusCode != 200) throw _error(res.statusCode, res.body);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final list = decoded['peers'] as List? ?? const [];
    return [
      for (final entry in list) _peerFromJson(entry as Map<String, dynamic>)
    ];
  }

  /// `NodeInfo.toJson` omits observer-side fields; `/v1/peers` adds an explicit
  /// `isSelf` marker for the queried node, which is read back here (#34).
  static NodeInfo _peerFromJson(Map<String, dynamic> json) {
    final info = NodeInfo.fromJson(json);
    return json['isSelf'] == true ? info.copyWith(isSelf: true) : info;
  }

  @override
  Future<({String host, int port, int budgetBytes})> startRpc(
    Uri base, {
    required String sessionId,
    required ModelRef model,
    required String coordinatorId,
  }) async {
    final res = await _post(base, '/v1/rpc/start', {
      'sessionId': sessionId,
      'model': model.toString(),
      'coordinatorId': coordinatorId,
    });
    if (res.statusCode != 200) throw _error(res.statusCode, res.body);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      host: decoded['host'] as String? ?? base.host,
      port: (decoded['port'] as num).toInt(),
      budgetBytes: (decoded['budgetBytes'] as num).toInt(),
    );
  }

  @override
  Future<void> stopRpc(Uri base, String sessionId) async {
    final res = await _post(base, '/v1/rpc/stop', {'sessionId': sessionId});
    if (res.statusCode != 200) throw _error(res.statusCode, res.body);
  }

  @override
  Future<SessionInfo?> session(Uri base) async {
    final res = await _get(base, '/v1/session');
    if (res.statusCode != 200) throw _error(res.statusCode, res.body);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final s = decoded['session'];
    return s == null ? null : SessionInfo.fromJson(s as Map<String, dynamic>);
  }

  @override
  Stream<ChatDelta> chat(
    Uri base,
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
    bool asCoordinator = false,
  }) async* {
    final body = <String, dynamic>{
      'model': model.toString(),
      'messages': [for (final m in messages) m.toJson()],
      'stream': true,
    };
    if (temperature != null) body['temperature'] = temperature;
    if (maxTokens != null) body['max_tokens'] = maxTokens;

    final request = http.Request('POST', _uri(base, '/v1/chat/completions'))
      ..headers.addAll(_headers(base))
      ..body = jsonEncode(body);
    if (asCoordinator) request.headers[kHeaderChatRoute] = kRouteCoordinator;

    final http.StreamedResponse res;
    try {
      // Chat waits for the coordinator's first token (cold model load), which is
      // far longer than a regular API call; never apply the 5 s API timeout here.
      res = await _http.send(request).timeout(chatTimeout);
    } on TimeoutException {
      throw LlmmbcException('engine_error',
          'chat request timed out after ${chatTimeout.inSeconds}s waiting for the first byte');
    } on SocketException catch (e) {
      throw LlmmbcException('engine_error', 'cannot reach node: ${e.message}');
    }

    if (res.statusCode != 200) {
      final text = await res.stream.bytesToString();
      throw _error(res.statusCode, text);
    }

    // The coordinator announces itself in `X-LLMMBC-Node`; fall back to the
    // response header seen by the caller when it is absent.
    final servedBy = res.headers[kHeaderNode.toLowerCase()] ??
        res.headers[kHeaderNode] ??
        base.host;
    final deltas = parseOpenAiSse(res.stream, servedBy: servedBy);
    // Once streaming, a silent stream means the coordinator/engine went away.
    yield* _withIdleTimeout(deltas, chatIdleTimeout);
  }

  /// Fails the stream with `engine_error` when no chunk arrives for [idle].
  ///
  /// A manual watchdog is used instead of `Stream.timeout` so the pending HTTP
  /// subscription is cancelled explicitly and the error is delivered at once.
  Stream<ChatDelta> _withIdleTimeout(Stream<ChatDelta> source, Duration idle) {
    late StreamController<ChatDelta> controller;
    StreamSubscription<ChatDelta>? subscription;
    Timer? timer;
    var closed = false;

    void finish() {
      if (closed) return;
      closed = true;
      timer?.cancel();
      timer = null;
      controller.close();
    }

    void arm() {
      timer?.cancel();
      timer = Timer(idle, () {
        if (closed) return;
        closed = true;
        timer = null;
        controller.addError(LlmmbcException(
            'engine_error', 'chat stream stalled for ${idle.inSeconds}s'));
        controller.close();
        final pending = subscription;
        if (pending != null) {
          unawaited(pending.cancel().catchError((Object _) {}));
        }
      });
    }

    controller = StreamController<ChatDelta>(
      onListen: () {
        arm();
        subscription = source.listen(
          (delta) {
            if (closed) return;
            arm();
            controller.add(delta);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (closed) return;
            closed = true;
            timer?.cancel();
            controller.addError(error, stackTrace);
            controller.close();
          },
          onDone: finish,
          cancelOnError: true,
        );
      },
      onPause: () {
        timer?.cancel();
      },
      onResume: () {
        if (!closed) arm();
      },
      onCancel: () {
        timer?.cancel();
        final pending = subscription;
        if (pending != null) {
          unawaited(pending.cancel().catchError((Object _) {}));
        }
      },
    );
    return controller.stream;
  }

  /// Releases the underlying HTTP client. Not part of [NodeClient]; used by owners.
  void close() => _http.close();
}
