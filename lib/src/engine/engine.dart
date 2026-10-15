import '../errors.dart';
import '../protocol/codec.dart';
import '../types/connection.dart';
import '../types/live.dart';
import '../value/value.dart';
import 'session_state.dart';

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
  /// A [session] runs it in that attached session and a [txn] inside that
  /// transaction.
  Future<Object?> rpc(String method, List<Object?> params,
      {Uuid? session, Uuid? txn});

  /// Whether this engine can stream replies with [rpcStream].
  bool get supportsStreaming;

  /// Sends an RPC call whose reply arrives as several messages, such as
  /// `query_stream`, and emits the result of each one. The stream closes
  /// after a result that is a map with `stream: end`, and fails on an error
  /// reply. Cancelling the subscription early cancels the call on the
  /// server. Engines that cannot stream throw [UnsupportedFeatureError].
  Stream<Object?> rpcStream(String method, List<Object?> params,
      {Uuid? session, Uuid? txn});

  /// Whether this engine can attach sessions and run transactions, which
  /// need a connection that outlives a single request.
  bool get supportsSessions;

  /// Starts tracking the [state] of the attached session [id], so its
  /// requests keep it up to date and a reconnect attaches it again and
  /// replays it.
  void trackSession(Uuid id, SessionState state);

  /// Stops tracking the attached session [id].
  void untrackSession(Uuid id);

  /// The current connection status.
  ConnectionStatus get status;

  /// Emits whenever the connection status changes.
  Stream<ConnectionStatus> get statusChanges;

  /// Whether this engine can run live queries.
  bool get supportsLiveQueries;

  /// Emits live query notifications. Engines that do not support live queries
  /// never emit on this stream.
  Stream<LiveMessage> get liveNotifications;

  /// Called after a dropped connection has been re established. The driver uses
  /// this to restart live queries.
  set onReconnect(Future<void> Function()? handler);

  /// Called when a reconnect could not restore authentication, for example
  /// because the token expired while the connection was down. The connection
  /// continues without authentication.
  set onAuthenticationLost(void Function(Object error)? handler);
}
