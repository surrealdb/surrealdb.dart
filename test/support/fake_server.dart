import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:surrealdb/surrealdb.dart';

/// A request received by a [FakeSurrealServer].
class FakeRequest {
  FakeRequest(this.socket, this.id, this.method, this.params, this.raw);

  final WebSocket socket;
  final Object? id;
  final String method;
  final List<Object?> params;

  /// The whole decoded request envelope, including any `session` or `txn`.
  final Map<dynamic, dynamic> raw;
}

/// What a [FakeSurrealServer] handler wants sent back for a request.
sealed class FakeReply {
  const FakeReply();
}

/// Reply with a result.
class FakeResult extends FakeReply {
  const FakeResult(this.result);
  final Object? result;
}

/// Reply with an RPC error.
class FakeError extends FakeReply {
  const FakeError(this.message, {this.code = -32000, this.extra = const {}});
  final String message;
  final int code;
  final Map<String, Object?> extra;
}

/// Send nothing, so the request never completes.
class FakeSilence extends FakeReply {
  const FakeSilence();
}

/// A WebSocket server that speaks the SurrealDB RPC envelope over CBOR, for
/// testing engine behaviour that a real server cannot easily be made to show,
/// such as dropped connections, expired tokens and requests that never reply.
class FakeSurrealServer {
  FakeSurrealServer._(this._server);

  final HttpServer _server;
  final _codec = const CborCodec();
  final List<WebSocket> _sockets = [];
  final List<FakeRequest> requests = [];

  /// Decides the reply to each request. The default answers every request
  /// with a null result, `version` with a 3.x version, `live` with a fresh id
  /// and `query` with one null statement result per `;`-separated statement.
  FakeReply Function(FakeRequest request) handler = defaultReply;

  /// How many connections have been accepted in total.
  int accepted = 0;

  static Future<FakeSurrealServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSurrealServer._(server);
    server.listen(fake._onRequest);
    return fake;
  }

  static var _liveCounter = 0;

  static FakeReply defaultReply(FakeRequest request) =>
      switch (request.method) {
        'version' => const FakeResult('surrealdb-3.3.4'),
        'live' => FakeResult(Uuid(
            '00000000-0000-4000-8000-${(_liveCounter++).toString().padLeft(12, '0')}')),
        'query' => FakeResult([
            for (var i = 0;
                i < ';'.allMatches('${request.params.first}').length + 1;
                i++)
              {'status': 'OK', 'time': '1ms', 'result': null},
          ]),
        _ => const FakeResult(null),
      };

  String get url => 'ws://127.0.0.1:${_server.port}/rpc';

  /// Connections the server still holds open.
  int get openConnections =>
      _sockets.where((s) => s.readyState == WebSocket.open).length;

  /// The methods received so far, in order.
  List<String> get methods => [for (final r in requests) r.method];

  Future<void> _onRequest(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) => protocols.first,
    );
    accepted++;
    _sockets.add(socket);
    socket.listen((data) {
      final decoded = _codec.decode(data as List<int>) as Map;
      final req = FakeRequest(
          socket,
          decoded['id'],
          decoded['method'] as String,
          (decoded['params'] as List?) ?? const [],
          decoded);
      requests.add(req);
      switch (handler(req)) {
        case FakeResult(:final result):
          _send(socket, {'id': req.id, 'result': result});
        case FakeError(:final message, :final code, :final extra):
          _send(socket, {
            'id': req.id,
            'error': {'code': code, 'message': message, ...extra},
          });
        case FakeSilence():
          break;
      }
    });
  }

  /// Sends a message that is not a reply, such as a live notification.
  void push(Object? message) {
    for (final socket in _sockets) {
      _send(socket, message);
    }
  }

  /// Sends on [socket] unless it has already closed.
  void _send(WebSocket socket, Object? message) {
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(_codec.encode(message));
    } on StateError {
      // The socket closed between the check and the write.
    }
  }

  /// Drops every open connection, as a network failure would.
  Future<void> dropAll() async {
    for (final socket in List.of(_sockets)) {
      await socket.close(WebSocketStatus.goingAway);
    }
  }

  Future<void> close() async {
    await dropAll();
    await _server.close(force: true);
  }
}

/// Waits until [condition] holds, polling briefly, or fails after [timeout].
Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A JWT whose payload expires [expiresIn] from now. The signature is not
/// valid; only the client reads it.
String fakeJwt(Duration expiresIn, {String id = 'a'}) {
  String encode(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final exp = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return '${encode({'alg': 'HS512'})}.${encode({'exp': exp, 'jti': id})}.sig';
}
