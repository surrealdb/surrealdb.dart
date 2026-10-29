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
    Duration? requestTimeout,
  })  : _codec = codec,
        _protocol = RpcProtocol(codec),
        _reconnect = reconnect,
        _requestTimeout = requestTimeout;

  final SurrealCodec _codec;
  final RpcProtocol _protocol;
  final ReconnectOptions _reconnect;
  final Duration? _requestTimeout;
  final _pending = <String, Completer<Object?>>{};
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _liveController = StreamController<LiveMessage>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Uri? _url;
  Duration _timeout = const Duration(seconds: 30);
  var _intentionalClose = false;
  var _reconnecting = false;

  // Session state, replayed after a reconnect.
  String? _namespace;
  String? _database;
  String? _token;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  Future<void> Function()? _onReconnect;
  void Function(Object error)? _onAuthenticationLost;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get statusChanges => _statusController.stream;

  @override
  Stream<LiveMessage> get liveNotifications => _liveController.stream;

  @override
  set onReconnect(Future<void> Function()? handler) => _onReconnect = handler;

  @override
  set onAuthenticationLost(void Function(Object error)? handler) =>
      _onAuthenticationLost = handler;

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
    _setStatus(ConnectionStatus.connecting);
    await _connect();
    _setStatus(ConnectionStatus.connected);
  }

  /// Opens a socket and makes it the current channel. On failure the socket
  /// is closed, so a failed attempt never leaves a connection behind.
  Future<void> _connect() async {
    final channel = WebSocketChannel.connect(_url!, protocols: [_codec.name]);
    try {
      await channel.ready.timeout(_timeout);
    } catch (error) {
      unawaited(_closeChannel(channel));
      if (error is TimeoutException) {
        throw const SurrealError('Timed out while connecting to the server');
      }
      throw SurrealError('Failed to connect to the server', cause: error);
    }
    _channel = channel;
    _subscription = channel.stream.listen(
      _onMessage,
      // Events from a socket that has since been replaced are ignored.
      onError: (Object error) {
        if (identical(_channel, channel)) _onDisconnected(error);
      },
      onDone: () {
        if (identical(_channel, channel)) _onDisconnected(null);
      },
    );
  }

  Future<void> _closeChannel(WebSocketChannel channel) async {
    try {
      await channel.sink.close().timeout(_timeout);
    } catch (_) {
      // The socket is already gone.
    }
  }

  /// Closes the current socket, if any, without triggering a reconnect.
  Future<void> _dropChannel() async {
    final channel = _channel;
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    await subscription?.cancel();
    if (channel != null) await _closeChannel(channel);
  }

  @override
  Future<void> close() async {
    _intentionalClose = true;
    await _dropChannel();
    _failPending(const ConnectionUnavailableError());
    _setStatus(ConnectionStatus.disconnected);
  }

  @override
  Future<Object?> rpc(String method, List<Object?> params) async {
    if (_status != ConnectionStatus.connected) {
      throw const ConnectionUnavailableError();
    }
    return _call(method, params);
  }

  /// Sends a request on the current socket. Unlike [rpc] this does not need
  /// the connection to be fully restored, so it is used to replay the session.
  Future<Object?> _call(String method, List<Object?> params) async {
    final channel = _channel;
    if (channel == null) throw const ConnectionUnavailableError();
    final id = _protocol.nextId();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final payload = _protocol.encodeRequest(id, method, params);
    channel.sink.add(_codec.isBinary ? payload : utf8.decode(payload));
    final timeout = _requestTimeout;
    final Object? result;
    if (timeout == null) {
      result = await completer.future;
    } else {
      result = await completer.future.timeout(timeout, onTimeout: () {
        // Forget the request, so a late reply is dropped.
        _pending.remove(id);
        // The server may still have applied a change to the session, so it
        // may no longer match the one tracked here. Start again on a new
        // socket, which restores the session as it is known.
        if (_sessionMethods.contains(method)) _resetChannel(channel);
        throw RequestTimeoutError(method, timeout);
      });
    }
    _trackSession(method, params, result);
    return result;
  }

  /// Calls that change the server's session.
  static const _sessionMethods = {
    'use',
    'signin',
    'signup',
    'authenticate',
    'invalidate',
    'let',
    'unset',
  };

  /// Abandons [channel] as if the server had dropped it, so the usual
  /// reconnect follows.
  void _resetChannel(WebSocketChannel channel) {
    if (!identical(_channel, channel)) return;
    final subscription = _subscription;
    _onDisconnected(null);
    unawaited(subscription?.cancel());
    unawaited(_closeChannel(channel));
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
    // A drop while a reconnect is under way is handled by that loop.
    if (_reconnecting) return;
    if (_reconnect.enabled) {
      unawaited(_reconnectLoop());
    } else {
      _setStatus(ConnectionStatus.disconnected);
    }
  }

  Future<void> _reconnectLoop() async {
    _reconnecting = true;
    _setStatus(ConnectionStatus.reconnecting);
    try {
      var attempt = 0;
      while (!_intentionalClose &&
          (_reconnect.attempts < 0 || attempt < _reconnect.attempts)) {
        attempt++;
        await Future<void>.delayed(_reconnect.delayForAttempt(attempt));
        if (_intentionalClose) return;
        try {
          await _connect();
          await _restoreSession();
        } catch (_) {
          // Close whatever this attempt opened before trying again.
          await _dropChannel();
          continue;
        }
        if (_intentionalClose) return;
        _setStatus(ConnectionStatus.connected);
        try {
          await _onReconnect?.call();
        } catch (_) {
          // The hook reports its own failures, such as a live query that
          // could not be restarted. The connection itself is restored.
        }
        // A drop while the hook ran was not handled, because this loop was
        // still running, so try again.
        if (_channel == null && !_intentionalClose) {
          _setStatus(ConnectionStatus.reconnecting);
          continue;
        }
        return;
      }
      if (!_intentionalClose) _setStatus(ConnectionStatus.disconnected);
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _restoreSession() async {
    if (_namespace != null || _database != null) {
      await _call('use', [_namespace, _database]);
    }
    final token = _token;
    if (token != null) {
      try {
        await _call('authenticate', [token]);
      } on ResponseError catch (error) {
        // The server rejected the token, for example because it expired. The
        // connection itself is fine, so carry on without authentication
        // rather than failing every attempt.
        _token = null;
        _onAuthenticationLost?.call(error);
      }
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
