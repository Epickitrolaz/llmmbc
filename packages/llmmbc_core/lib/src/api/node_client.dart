// core-net: HTTP client for another node's API (docs/ARCHITECTURE.md §3).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';
import 'sse.dart';

/// `NodeClient` implementation over `package:http`.
class HttpNodeClient implements NodeClient {
  final Duration timeout;
  final http.Client _http;

  HttpNodeClient(
      {this.timeout = const Duration(seconds: 5), http.Client? client})
      : _http = client ?? http.Client();

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
    return [for (final p in list) NodeInfo.fromJson(p as Map<String, dynamic>)];
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

    final http.StreamedResponse res;
    try {
      res = await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw LlmmbcException('engine_error', 'chat request timed out');
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
    yield* parseOpenAiSse(res.stream, servedBy: servedBy);
  }

  /// Releases the underlying HTTP client. Not part of [NodeClient]; used by owners.
  void close() => _http.close();
}
