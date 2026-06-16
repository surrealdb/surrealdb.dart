import '../types/connection.dart';
import '../types/live.dart';

/// Transport that carries RPC calls to a SurrealDB instance.
///
/// Implementations are selected by the URL scheme: `ws`/`wss` use the
/// WebSocket engine, `http`/`https` use the HTTP engine.
abstract class Engine {
  /// Opens the connection.
  Future<void> open(Uri url, {Duration timeout = const Duration(seconds: 30)});

  /// Closes the connection and releases any resources.
  Future<void> close();

  /// Sends an RPC call and completes with its result, or throws on error.
  Future<Object?> rpc(String method, List<Object?> params);

  /// The current connection status.
  ConnectionStatus get status;

  /// Emits whenever the connection status changes.
  Stream<ConnectionStatus> get statusChanges;

  /// Emits live query notifications. Engines that do not support live queries
  /// never emit on this stream.
  Stream<LiveMessage> get liveNotifications;

  /// Called after a dropped connection has been re established. The driver uses
  /// this to restart live queries.
  set onReconnect(Future<void> Function()? handler);
}
