part of 'surreal.dart';

/// An interactive transaction, started with `beginTransaction`.
///
/// Queries and record operations run on the transaction see each other's
/// changes, and nothing is visible to anyone else until [commit]. [cancel]
/// discards every change. Transactions need the WebSocket engine and
/// SurrealDB 3.0 or later.
///
/// ```dart
/// final txn = await db.beginTransaction();
/// try {
///   await txn.create(const RecordId('account', 'a'), {'balance': 90});
///   await txn.create(const RecordId('account', 'b'), {'balance': 110});
/// } catch (_) {
///   await txn.cancel();
///   rethrow;
/// }
/// // Outside the try: a commit that fails has already ended the transaction.
/// await txn.commit();
/// ```
///
/// A transaction lives on the server connection, so it is lost if the
/// connection drops, or the session is reset or closed: later calls on it
/// then fail with a [ServerError] saying it was not found.
final class SurrealTransaction with SurrealQueryable {
  SurrealTransaction._(this._client, this._session, this.id);

  @override
  final Surreal _client;
  final Uuid? _session;

  /// The server's id for this transaction.
  final Uuid id;

  var _done = false;

  /// Completes, for each stream being read, when it has ended.
  final _openStreams = <Future<void>>{};

  /// Whether [commit] or [cancel] has been called.
  bool get isDone => _done;

  /// Commits every change made in the transaction, once every stream from
  /// [queryStream] that is still being read has ended.
  Future<void> commit() async {
    _checkOpen();
    _done = true;
    // Committing ends the transaction, which would cut such a stream short.
    await Future.wait(List.of(_openStreams));
    await _client._rpc('commit', [id], session: _session);
  }

  /// Discards every change made in the transaction.
  Future<void> cancel() async {
    _checkOpen();
    _done = true;
    await _client._rpc('cancel', [id], session: _session);
  }

  void _checkOpen() {
    if (_done) throw const TransactionClosedError();
  }

  @override
  Future<Object?> _call(String method, [List<Object?> params = const []]) {
    _checkOpen();
    return _client._rpc(method, params, session: _session, txn: id);
  }

  /// Like [SurrealQueryable.queryStream]. [commit] waits for the stream to
  /// end, also when the query runs buffered on a server without streaming.
  @override
  Stream<QueryFrame> queryStream(String query,
      {Map<String, Object?>? bindings}) {
    _checkOpen();
    // The stream checks the transaction is open when it is listened to, not
    // as its calls go out: [commit] waits for a stream listened to before
    // it, whose calls may only go out after.
    return _tracked(_streamQuery(query, bindings,
        call: (method, params) =>
            _client._rpc(method, params, session: _session, txn: id),
        callStream: (method, params) =>
            _client._rpcStream(method, params, session: _session, txn: id)));
  }

  @override
  Stream<Object?> _callStream(String method, List<Object?> params) {
    _checkOpen();
    return _client._rpcStream(method, params, session: _session, txn: id);
  }

  /// [source], tracked in [_openStreams] from when it is listened to until
  /// it ends.
  Stream<T> _tracked<T>(Stream<T> source) {
    final ended = Completer<void>();
    void end() {
      if (ended.isCompleted) return;
      ended.complete();
      _openStreams.remove(ended.future);
    }

    StreamSubscription<T>? subscription;
    late final StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () {
        if (_done) {
          controller
            ..addError(const TransactionClosedError())
            ..close();
          return;
        }
        _openStreams.add(ended.future);
        subscription = source
            .listen(controller.add, onError: controller.addError, onDone: () {
          end();
          controller.close();
        });
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      // A cancelled stream has ended once the server has stopped it.
      onCancel: () async {
        try {
          await subscription?.cancel();
        } finally {
          end();
        }
      },
    );
    return controller.stream;
  }
}
