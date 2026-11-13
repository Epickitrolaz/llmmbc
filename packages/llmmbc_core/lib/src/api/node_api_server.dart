// core-net: node HTTP API server (docs/ARCHITECTURE.md §3).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';
import '../node/node_service.dart';
import 'sse.dart';

const Map<String, int> _errorStatus = {
  'bad_request': 400,
  'not_found': 404,
  'busy': 409,
  'not_candidate': 403,
  'no_candidates': 409,
  'does_not_fit': 507,
  'engine_error': 500,
  'internal': 500,
};

class NodeApiServer {
  final NodeService _service;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  NodeApiServer(NodeService service) : _service = service;

  /// Binds and returns the actual port.
  Future<int> start({String host = '0.0.0.0', required int port}) async {
    final server = await HttpServer.bind(host, port);
    _server = server;
    _subscription = server.listen(_handle, onError: (_) {});
    return server.port;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
  }

  int get port => _server?.port ?? 0;

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _cors(response);
    try {
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v1/node') {
        await _json(response, _service.self.toJson());
      } else if (request.method == 'GET' && path == '/v1/peers') {
        final list = <NodeInfo>[
          _service.self.copyWith(isSelf: true),
          ..._service.discovery.peers
        ];
        await _json(response, {
          'peers': [for (final p in list) p.toJson()]
        });
      } else if (request.method == 'GET' && path == '/v1/models') {
        final models = await _service.models.list();
        await _json(response, {
          'models': [for (final m in models) m.toJson()]
        });
      } else if (request.method == 'GET' && path == '/v1/session') {
        final session = _service.currentSession;
        await _json(response, {'session': session?.toJson()});
      } else if (request.method == 'POST' && path == '/v1/rpc/start') {
        await _handleRpcStart(request, response);
      } else if (request.method == 'POST' && path == '/v1/rpc/stop') {
        await _handleRpcStop(request, response);
      } else if (request.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChat(request, response);
      } else {
        throw LlmmbcException(
            'not_found', 'no route for ${request.method} $path');
      }
    } on LlmmbcException catch (e) {
      await _error(response, e);
    } catch (e) {
      await _error(response, LlmmbcException('internal', e.toString()));
    }
  }

  LocalNodeService get _local {
    final s = _service;
    if (s is LocalNodeService) return s;
    throw LlmmbcException('internal', 'API server requires a LocalNodeService');
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      if (text.trim().isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected a JSON object');
      }
      return decoded;
    } on FormatException catch (e) {
      throw LlmmbcException('bad_request', 'invalid JSON body: ${e.message}');
    }
  }

  Future<void> _handleRpcStart(
      HttpRequest request, HttpResponse response) async {
    final body = await _readJson(request);
    final sessionId = body['sessionId'];
    final modelRef = body['model'];
    final coordinatorId = body['coordinatorId'];
    if (sessionId is! String ||
        modelRef is! String ||
        coordinatorId is! String) {
      throw LlmmbcException(
          'bad_request', 'sessionId, model and coordinatorId are required');
    }
    final ModelRef model;
    try {
      model = ModelRef.parse(modelRef);
    } on FormatException {
      throw LlmmbcException('bad_request', 'invalid model ref: $modelRef');
    }
    final hostHeader = request.headers.host;
    final hostHint = (hostHeader == null || hostHeader.isEmpty)
        ? null
        : (hostHeader.contains(':') ? hostHeader.split(':').first : hostHeader);
    final result = await _local.handleRpcStart(
      sessionId: sessionId,
      model: model,
      coordinatorId: coordinatorId,
      hostHint: hostHint,
    );
    await _json(response, {
      'host': result.host,
      'port': result.port,
      'budgetBytes': result.budgetBytes,
    });
  }

  Future<void> _handleRpcStop(
      HttpRequest request, HttpResponse response) async {
    final body = await _readJson(request);
    final sessionId = body['sessionId'];
    if (sessionId is! String) {
      throw LlmmbcException('bad_request', 'sessionId is required');
    }
    await _local.handleRpcStop(sessionId);
    await _json(response, {'ok': true});
  }

  Future<void> _handleChat(HttpRequest request, HttpResponse response) async {
    final body = await _readJson(request);
    final modelRef = body['model'];
    if (modelRef is! String) {
      throw LlmmbcException('bad_request', 'model is required');
    }
    final ModelRef model;
    try {
      model = ModelRef.parse(modelRef);
    } on FormatException {
      throw LlmmbcException('bad_request', 'invalid model ref: $modelRef');
    }
    final rawMessages = body['messages'];
    if (rawMessages is! List) {
      throw LlmmbcException('bad_request', 'messages must be a list');
    }
    final List<ChatMessage> messages;
    try {
      messages = [
        for (final m in rawMessages)
          ChatMessage.fromJson(m as Map<String, dynamic>)
      ];
    } catch (_) {
      throw LlmmbcException('bad_request', 'invalid messages');
    }
    final temperature = (body['temperature'] as num?)?.toDouble();
    final maxTokens = (body['max_tokens'] as num?)?.toInt();
    final stream = body['stream'] as bool? ?? true;

    final deltas = _local.handleChat(model, messages,
        temperature: temperature, maxTokens: maxTokens);
    if (stream) {
      await _streamChat(response, model, deltas);
    } else {
      await _bufferedChat(response, model, deltas);
    }
  }

  Future<void> _streamChat(
      HttpResponse response, ModelRef model, Stream<ChatDelta> deltas) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.headers.set('Connection', 'keep-alive');
    response.bufferOutput = false;
    final id = 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      await for (final delta in deltas) {
        response.write(encodeOpenAiSseChunk(
          id: id,
          model: model.toString(),
          created: created,
          content: delta.content,
          finishReason: delta.finishReason,
        ));
        await response.flush();
      }
      response.write('data: [DONE]\n\n');
    } on LlmmbcException catch (e) {
      response.write('data: ${jsonEncode(e.toJson())}\n\n');
      response.write('data: [DONE]\n\n');
    } catch (e) {
      response.write(
          'data: ${jsonEncode(LlmmbcException('engine_error', e.toString()).toJson())}\n\n');
      response.write('data: [DONE]\n\n');
    }
    await response.close();
  }

  Future<void> _bufferedChat(
      HttpResponse response, ModelRef model, Stream<ChatDelta> deltas) async {
    final buffer = StringBuffer();
    String? finish;
    await for (final delta in deltas) {
      buffer.write(delta.content);
      finish ??= delta.finishReason;
    }
    await _json(response, {
      'id': 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}',
      'object': 'chat.completion',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': model.toString(),
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': buffer.toString()},
          'finish_reason': finish ?? 'stop',
        }
      ],
      'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0},
    });
  }

  void _cors(HttpResponse response) {
    response.headers.set(kHeaderProtocol, '$kProtocolVersion');
    response.headers.set(kHeaderNode, _service.self.nodeId);
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers',
        'Content-Type, $kHeaderProtocol, $kHeaderNode');
  }

  Future<void> _json(HttpResponse response, Object body) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _error(HttpResponse response, LlmmbcException error) async {
    try {
      response.statusCode = error.httpStatus ??
          _errorStatus[error.code] ??
          HttpStatus.internalServerError;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(error.toJson()));
      await response.close();
    } on StateError {
      // Headers already went out (streaming response); just close the connection.
      try {
        await response.close();
      } on Object {
        // ignore
      }
    }
  }
}
