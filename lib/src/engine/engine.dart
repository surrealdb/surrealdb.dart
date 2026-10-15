import '../protocol/codec.dart';
import '../types/connection.dart';
import '../types/live.dart';

/// Transport that carries RPC calls to a SurrealDB instance.
///
/// Implementations are selected by the URL scheme: `ws`/`wss` use the
/// WebSocket engine, `http`/`https` use the HTTP engine.
abstract class Engine {
  /// Opens the connection.
  Future<void> open(Uri url, {Duration timeout = const Duration(seconds: 30)});

  /// The codec requests and replies are encoded with. It can be replaced by
  /// one of the same format, for example once the server version is known.
  SurrealCodec get codec;
  set codec(SurrealCodec value);

  /// Closes the connection and releases any resources.
  Future<void> close();

  /// Sends an RPC call and completes with its result, or throws on error.
  Future<Object?> rpc(String method, List<Object?> params);

  /// The current connection status.
  ConnectionStatus get status;

  /// Emits whenever the connection status changes.
  Stream<ConnectionStatus> get statusChanges;

  /// Whether this engine can run live queries.
  bool get supportsLiveQueries;

  /// Emits live query notifications. Engines that do not support live queries
  /// never emit on this stream.
  Stream<LiveMessage> get liveNotifications;

  /// Called on a re established connection before the session is restored
  /// and before it is reported as connected, with a function that sends calls
  /// on it. The driver uses this to check the server again. If it throws, the
  /// attempt counts as failed and is tried again, unless the handler closed
  /// the engine.
  set onVerify(
      Future<void> Function(
              Future<Object?> Function(String method, List<Object?> params)
                  call)?
          handler);

  /// Called after a dropped connection has been re established. The driver uses
  /// this to restart live queries.
  set onReconnect(Future<void> Function()? handler);

  /// Called when a reconnect could not restore authentication because the
  /// server rejected the tokens, for example because they expired while the
  /// connection was down, with a function that sends calls on the new
  /// connection. The driver can sign in again with it; otherwise the
  /// connection continues without authentication. If it throws, the attempt
  /// counts as failed and is tried again.
  set onAuthenticationLost(
      Future<void> Function(
              Object error,
              Future<Object?> Function(String method, List<Object?> params)
                  call)?
          handler);
}
