import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../errors.dart';
import '../protocol/codec.dart';
import '../types/connection.dart';
import '../types/live.dart';
import 'engine.dart';
import 'rpc.dart';

/// Carries RPC over a WebSocket. Supports live queries and automatic
/// reconnection. The serialization is set by the [SurrealCodec] it is given,
/// which also selects the WebSocket subprotocol.
class WebSocketEngine implements Engine {
  WebSocketEngine(
    SurrealCodec codec, {
    ReconnectOptions reconnect = const ReconnectOptions(),
  })  : _codec = codec,
        _protocol = RpcProtocol(codec),
        _reconnect = reconnect;

  final SurrealCodec _codec;
  final RpcProtocol _protocol;
  final ReconnectOptions _reconnect;
  final _pending = <String, Completer<Object?>>{};
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _liveController = StreamController<LiveMessage>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Uri? _url;
  Duration _timeout = const Duration(seconds: 30);
  var _intentionalClose = false;

  // Session state, replayed after a reconnect.
  String? _namespace;
  String? _database;
  String? _token;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  Future<void> Function()? _onReconnect;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get statusChanges => _statusController.stream;

  @override
  Stream<LiveMessage> get liveNotifications => _liveController.stream;

  @override
  set onReconnect(Future<void> Function()? handler) => _onReconnect = handler;

  void _setStatus(ConnectionStatus value) {
    if (_status == value) return;
    _status = value;
    if (!_statusController.isClosed) _statusController.add(value);
  }

  @override
  Future<void> open(Uri url,
      {Duration timeout = const Duration(seconds: 30)}) async {
    _url = url;
    _timeout = timeout;
    _intentionalClose = false;
    await _connect();
  }

  Future<void> _connect() async {
    _setStatus(_status == ConnectionStatus.disconnected
        ? ConnectionStatus.connecting
        : ConnectionStatus.reconnecting);
    final channel = WebSocketChannel.connect(_url!, protocols: [_codec.name]);
    try {
      await channel.ready.timeout(_timeout);
    } on TimeoutException {
      throw const SurrealError('Timed out while connecting to the server');
    } catch (error) {
      throw SurrealError('Failed to connect to the server', cause: error);
    }
    _channel = channel;
    _subscription = channel.stream.listen(
      _onMessage,
      onError: (Object error) => _onDisconnected(error),
      onDone: () => _onDisconnected(null),
    );
    _setStatus(ConnectionStatus.connected);
  }

  @override
  Future<void> close() async {
    _intentionalClose = true;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _failPending(const ConnectionUnavailableError());
    _setStatus(ConnectionStatus.disconnected);
  }

  @override
  Future<Object?> rpc(String method, List<Object?> params) async {
    final channel = _channel;
    if (channel == null || _status != ConnectionStatus.connected) {
      throw const ConnectionUnavailableError();
    }
    final id = _protocol.nextId();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final payload = _protocol.encodeRequest(id, method, params);
    channel.sink.add(_codec.isBinary ? payload : utf8.decode(payload));
    final result = await completer.future;
    _trackSession(method, params, result);
    return result;
  }

  void _trackSession(String method, List<Object?> params, Object? result) {
    switch (method) {
      case 'use':
        if (params.isNotEmpty && params[0] != null) {
          _namespace = params[0] as String;
        }
        if (params.length > 1 && params[1] != null) {
          _database = params[1] as String;
        }
      case 'signin':
      case 'signup':
        _token = _extractToken(result);
      case 'authenticate':
        if (params.isNotEmpty) _token = params[0] as String?;
      case 'invalidate':
        _token = null;
    }
  }

  String? _extractToken(Object? result) {
    if (result is String) return result;
    if (result is Map && result['token'] is String) {
      return result['token'] as String;
    }
    return null;
  }

  void _onMessage(dynamic data) {
    final bytes = data is String ? utf8.encode(data) : (data as List<int>);
    final incoming = _protocol.decodeIncoming(bytes);
    switch (incoming) {
      case RpcResponse(:final id, :final result, :final error)
          when _pending.containsKey(id):
        final completer = _pending.remove(id)!;
        if (error != null) {
          completer.completeError(error);
        } else {
          completer.complete(result);
        }
      case RpcNotification(:final message):
        if (!_liveController.isClosed) _liveController.add(message);
      default:
        break;
    }
  }

  void _onDisconnected(Object? error) {
    _subscription = null;
    _channel = null;
    if (_intentionalClose) return;
    _failPending(error == null
        ? const ConnectionUnavailableError()
        : SurrealError('Connection lost', cause: error));
    if (_reconnect.enabled) {
      unawaited(_reconnectLoop());
    } else {
      _setStatus(ConnectionStatus.disconnected);
    }
  }

  Future<void> _reconnectLoop() async {
    _setStatus(ConnectionStatus.reconnecting);
    var attempt = 0;
    while (!_intentionalClose &&
        (_reconnect.attempts < 0 || attempt < _reconnect.attempts)) {
      attempt++;
      await Future<void>.delayed(_reconnect.delayForAttempt(attempt));
      if (_intentionalClose) return;
      try {
        await _connect();
        await _restoreSession();
        await _onReconnect?.call();
        return;
      } catch (_) {
        _setStatus(ConnectionStatus.reconnecting);
      }
    }
    _setStatus(ConnectionStatus.disconnected);
  }

  Future<void> _restoreSession() async {
    if (_namespace != null || _database != null) {
      await rpc('use', [_namespace, _database]);
    }
    if (_token != null) {
      await rpc('authenticate', [_token]);
    }
  }

  void _failPending(Object error) {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
