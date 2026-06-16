import 'dart:async';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../protocol/codec.dart';
import '../types/connection.dart';
import '../types/live.dart';
import 'engine.dart';
import 'rpc.dart';

/// Carries RPC over HTTP by posting encoded messages to `/rpc`. The
/// serialization is set by the [SurrealCodec] it is given.
///
/// HTTP is stateless, so `use`, `authenticate`, and `invalidate` update local
/// header state rather than making a round trip, and live queries are not
/// supported.
class HttpEngine implements Engine {
  HttpEngine(SurrealCodec codec, {http.Client? client})
      : _codec = codec,
        _protocol = RpcProtocol(codec),
        _client = client ?? http.Client();

  final SurrealCodec _codec;
  final RpcProtocol _protocol;

  final http.Client _client;
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  Uri? _url;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  String? _namespace;
  String? _database;
  String? _token;

  /// The namespace currently selected for outgoing requests.
  String? get namespace => _namespace;

  /// The database currently selected for outgoing requests.
  String? get database => _database;

  /// The bearer token sent with outgoing requests.
  String? get token => _token;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get statusChanges => _statusController.stream;

  @override
  Stream<LiveMessage> get liveNotifications => const Stream.empty();

  @override
  set onReconnect(Future<void> Function()? handler) {}

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
  Future<Object?> rpc(String method, List<Object?> params) async {
    switch (method) {
      case 'use':
        if (params.isNotEmpty && params[0] != null) {
          _namespace = params[0] as String;
        }
        if (params.length > 1 && params[1] != null) {
          _database = params[1] as String;
        }
        return null;
      case 'authenticate':
        _token = params.isNotEmpty ? params[0] as String? : null;
        return null;
      case 'invalidate':
        _token = null;
        return null;
      case 'let':
      case 'unset':
      case 'live':
      case 'kill':
        throw UnsupportedFeatureError(method);
    }

    final result = await _send(method, params);
    if (method == 'signin' || method == 'signup') {
      _token = _extractToken(result);
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
      if (_token != null) 'Authorization': 'Bearer $_token',
      if (_namespace != null) 'Surreal-NS': _namespace!,
      if (_database != null) 'Surreal-DB': _database!,
    };
    final response = await _client.post(_url!, headers: headers, body: body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpConnectionError(
        'Request failed with status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _protocol.decodeResponse(response.bodyBytes);
    if (decoded.error != null) throw decoded.error!;
    return decoded.result;
  }

  String? _extractToken(Object? result) {
    if (result is String) return result;
    if (result is Map && result['token'] is String) {
      return result['token'] as String;
    }
    return null;
  }
}
