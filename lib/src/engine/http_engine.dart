import 'dart:async';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../protocol/codec.dart';
import '../types/connection.dart';
import '../types/live.dart';
import '../value/value.dart';
import 'engine.dart';
import 'rpc.dart';
import 'session_state.dart';

/// Carries RPC over HTTP by posting encoded messages to `/rpc`. The
/// serialization is set by the [SurrealCodec] it is given.
///
/// HTTP is stateless, so `use`, `authenticate`, and `invalidate` update local
/// header state rather than making a round trip, and live queries are not
/// supported.
class HttpEngine implements Engine {
  HttpEngine(
    SurrealCodec codec, {
    http.Client? client,
    Duration? requestTimeout = const Duration(seconds: 30),
    SessionState? session,
  })  : _session = session ?? SessionState(),
        _codec = codec,
        _protocol = RpcProtocol(codec),
        _client = client ?? http.Client(),
        _requestTimeout = requestTimeout;

  final SurrealCodec _codec;
  final RpcProtocol _protocol;

  final http.Client _client;
  final Duration? _requestTimeout;
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  Uri? _url;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  /// The session state sent with every request: the namespace and database
  /// as headers, the token as a bearer token and the variables merged into
  /// each query.
  final SessionState _session;

  /// The namespace currently selected for outgoing requests.
  String? get namespace => _session.namespace;

  /// The database currently selected for outgoing requests.
  String? get database => _session.database;

  /// The bearer token sent with outgoing requests.
  String? get token => _session.token;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get statusChanges => _statusController.stream;

  @override
  bool get supportsStreaming => false;

  @override
  bool get supportsLiveQueries => false;

  @override
  Stream<LiveMessage> get liveNotifications => const Stream.empty();

  @override
  set onReconnect(Future<void> Function()? handler) {}

  @override
  set onAuthenticationLost(void Function(Object error)? handler) {}

  @override
  Future<void> open(Uri url,
      {Duration timeout = const Duration(seconds: 30)}) async {
    _url = url;
    _status = ConnectionStatus.connected;
    _statusController.add(ConnectionStatus.connected);
  }

  @override
  Future<void> close() async {
    _client.close();
    _status = ConnectionStatus.disconnected;
    if (!_statusController.isClosed) {
      _statusController.add(ConnectionStatus.disconnected);
    }
  }

  @override
  Stream<Object?> rpcStream(String method, List<Object?> params,
          {Uuid? session, Uuid? txn}) =>
      throw const UnsupportedFeatureError('streaming');

  @override
  bool get supportsSessions => false;

  @override
  void trackSession(Uuid id, SessionState state) =>
      throw const UnsupportedFeatureError('sessions');

  @override
  void untrackSession(Uuid id) {}

  @override
  Future<Object?> rpc(String method, List<Object?> params,
      {Uuid? session, Uuid? txn}) async {
    if (session != null) throw const UnsupportedFeatureError('sessions');
    if (txn != null) throw const UnsupportedFeatureError('transactions');
    switch (method) {
      case 'attach':
      case 'detach':
      case 'sessions':
        throw const UnsupportedFeatureError('sessions');
      case 'begin':
      case 'commit':
      case 'cancel':
        throw const UnsupportedFeatureError('transactions');
      // Each HTTP request is its own server-side session, so session state is
      // kept here and sent with every request instead.
      case 'use':
      case 'authenticate':
      case 'invalidate':
      case 'let':
      case 'unset':
      case 'reset':
        _session.apply(method, params, null);
        return null;
      case 'live':
      case 'kill':
        throw UnsupportedFeatureError(method);
      case 'query':
      case 'gql':
        // Variables set with `let` apply to every query, under any bound in
        // the call itself.
        if (_session.variables.isNotEmpty) {
          final bindings = params.length > 1 ? params[1] : null;
          params = [
            params[0],
            {
              ..._session.variables,
              if (bindings is Map) ...bindings,
            },
            ...params.skip(2),
          ];
        }
    }

    final result = await _send(method, params);
    if (method == 'signin' || method == 'signup' || method == 'refresh') {
      _session.apply(method, params, result);
    }
    return result;
  }

  Future<Object?> _send(String method, List<Object?> params) async {
    if (_url == null) throw const ConnectionUnavailableError();
    final id = _protocol.nextId();
    final body = _protocol.encodeRequest(id, method, params);
    final headers = <String, String>{
      'Content-Type': _codec.contentType,
      'Accept': _codec.contentType,
      if (_session.token != null) 'Authorization': 'Bearer ${_session.token}',
      if (_session.namespace != null) 'Surreal-NS': _session.namespace!,
      if (_session.database != null) 'Surreal-DB': _session.database!,
    };
    final request = _client.post(_url!, headers: headers, body: body);
    final timeout = _requestTimeout;
    final response = timeout == null
        ? await request
        : await request.timeout(timeout,
            onTimeout: () => throw RequestTimeoutError(method, timeout));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Prefer the server's own error, when the body carries one.
      final error = _tryDecodeError(response.bodyBytes);
      if (error != null) throw error;
      throw HttpConnectionError(
        'Request failed with status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _protocol.decodeResponse(response.bodyBytes);
    if (decoded.error != null) throw decoded.error!;
    return decoded.result;
  }

  ResponseError? _tryDecodeError(List<int> body) {
    try {
      return _protocol.decodeResponse(body).error;
    } catch (_) {
      return null;
    }
  }
}
