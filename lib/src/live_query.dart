import 'dart:async';

import 'types/live.dart';
import 'value/value.dart';

/// A handle to an active live query.
///
/// Listen to [stream] for change notifications, and call [kill] to stop the
/// query. The stream is a broadcast stream, so it may have many listeners.
class LiveQuery {
  LiveQuery(this._id, this._kill);

  Uuid _id;
  final Future<void> Function(LiveQuery) _kill;
  final StreamController<LiveMessage> _controller =
      StreamController<LiveMessage>.broadcast();

  /// The id of the underlying live query. This changes if the connection drops
  /// and the query is restarted.
  Uuid get id => _id;

  /// The change notifications for this live query.
  Stream<LiveMessage> get stream => _controller.stream;

  /// Stops the live query and closes [stream].
  Future<void> kill() => _kill(this);

  /// Used by the driver to deliver a notification.
  void emit(LiveMessage message) {
    if (!_controller.isClosed) _controller.add(message);
  }

  /// Used by the driver to update the id after a reconnect.
  void rebind(Uuid id) => _id = id;

  /// Used by the driver to close the stream when the query is killed.
  Future<void> dispose() => _controller.close();
}
