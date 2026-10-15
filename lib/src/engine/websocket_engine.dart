import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../errors.dart';
import '../internal/jwt.dart';
import '../protocol/codec.dart';
import '../types/connection.dart';
import '../types/live.dart';
import '../value/value.dart';
import 'engine.dart';
import 'rpc.dart';
import 'session_state.dart';

/// Carries RPC over a WebSocket. Supports live queries and automatic
/// reconnection. The serialization is set by the [SurrealCodec] it is given,
/// which also selects the WebSocket subprotocol.
class WebSocketEngine implements Engine {
  WebSocketEngine(
    SurrealCodec codec, {
    ReconnectOptions reconnect = const ReconnectOptions(),
    Duration? requestTimeout = const Duration(seconds: 30),
    SessionState? session,
  })  : _session = session ?? SessionState(),
        _protocol = RpcProtocol(codec),
        _reconnect = reconnect,
        _requestTimeout = requestTimeout;

  SurrealCodec get _codec => _protocol.codec;

  @override
  SurrealCodec get codec => _protocol.codec;

  @override
  set codec(SurrealCodec value) => _protocol.codec = value;
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

  /// The state of the connection's default session, replayed after a
  /// reconnect.
  final SessionState _session;

  /// The state of each attached session, by id, attached again and replayed
  /// after a reconnect.
  final Map<Uuid, SessionState> _attached = {};

  @override
  bool get supportsSessions => true;

  @override
  void trackSession(Uuid id, SessionState state) => _attached[id] = state;

  @override
  void untrackSession(Uuid id) => _attached.remove(id);

  ConnectionStatus _status = ConnectionStatus.disconnected;
  Future<void> Function()? _onReconnect;
  Future<void> Function(
          Future<Object?> Function(String method, List<Object?> params) call)?
      _onVerify;
  Future<void> Function(Uuid? session, Object error,
          Future<Object?> Function(String method, List<Object?> params) call)?
      _onAuthenticationLost;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get statusChanges => _statusController.stream;

  @override
  bool get supportsLiveQueries => true;

  @override
  Stream<LiveMessage> get liveNotifications => _liveController.stream;

  @override
  set onVerify(
          Future<void> Function(
                  Future<Object?> Function(String method, List<Object?> params)
                      call)?
              handler) =>
      _onVerify = handler;

  @override
  set onReconnect(Future<void> Function()? handler) => _onReconnect = handler;

  @override
  set onAuthenticationLost(
          Future<void> Function(
                  Uuid? session,
                  Object error,
                  Future<Object?> Function(String method, List<Object?> params)
                      call)?
              handler) =>
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
  Future<Object?> rpc(String method, List<Object?> params,
      {Uuid? session, Uuid? txn}) async {
    if (_status != ConnectionStatus.connected) {
      throw const ConnectionUnavailableError();
    }
    return _call(method, params, session: session, txn: txn);
  }

  /// Sends a request on the current socket. Unlike [rpc] this does not need
  /// the connection to be fully restored, so it is used to replay the session.
  Future<Object?> _call(String method, List<Object?> params,
      {Uuid? session, Uuid? txn}) async {
    final channel = _channel;
    if (channel == null) throw const ConnectionUnavailableError();
    final id = _protocol.nextId();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final payload =
        _protocol.encodeRequest(id, method, params, session: session, txn: txn);
    // A variable is kept as it was sent, decoded from the request itself, so
    // that later changes to the caller's objects cannot change what a
    // reconnect replays.
    final sent = method == 'let' ? _paramsOf(payload) : params;
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
    (session == null ? _session : _attached[session])
        ?.apply(method, sent, result);
    return result;
  }

  List<Object?> _paramsOf(List<int> payload) =>
      ((_codec.decode(payload) as Map)['params'] as List).cast<Object?>();

  /// Calls that change the server's session.
  static const _sessionMethods = {
    'use',
    'signin',
    'signup',
    'authenticate',
    'invalidate',
    'let',
    'unset',
    'reset',
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
          // The server behind the URL may have changed, so it is checked
          // before anything is sent to it or anyone is told it is back.
          await _onVerify?.call(_call);
          await _restoreSession();
        } catch (_) {
          if (_intentionalClose) return;
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

  /// Replays the default session, then attaches and replays every attached
  /// session.
  Future<void> _restoreSession() async {
    await _restoreState(_session, null);
    for (final MapEntry(key: id, value: state) in _attached.entries.toList()) {
      // A session closed while earlier ones were replayed is left out.
      if (!identical(_attached[id], state)) continue;
      await _call('attach', const [], session: id);
      await _restoreState(state, id);
      // One closed while it was replayed could not send its own detach, as
      // the connection was not ready, so send it now.
      if (!identical(_attached[id], state)) {
        await _call('detach', const [], session: id);
      }
    }
  }

  Future<void> _restoreState(SessionState state, Uuid? session) async {
    if (state.namespace != null || state.database != null) {
      await _call('use', [state.namespace, state.database], session: session);
    }
    for (final MapEntry(:key, :value) in state.variables.entries.toList()) {
      await _call('let', [key, value], session: session);
    }
    final token = state.token;
    if (token != null) {
      final refresh = state.refreshToken;
      final expiry = tokenExpiry(token);
      final expired = expiry != null && !expiry.isAfter(DateTime.now().toUtc());
      final pair = {'access': token, 'refresh': refresh};
      try {
        if (expired && refresh != null) {
          await _call('refresh', [pair], session: session);
        } else {
          try {
            await _call('authenticate', [token], session: session);
          } on ResponseError catch (error) {
            if (refresh == null || !rejectsAuthentication(error)) rethrow;
            await _call('refresh', [pair], session: session);
          }
        }
      } on ResponseError catch (error) {
        // Any other failure fails the attempt, which is tried again.
        if (!rejectsAuthentication(error)) rethrow;
        // The server rejected the token, and the refresh token if there was
        // one, for example because they expired. The connection itself is
        // fine, so carry on without them rather than failing every attempt.
        state.setTokens(null, null);
        await _onAuthenticationLost?.call(session, error,
            (method, params) => _call(method, params, session: session));
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
