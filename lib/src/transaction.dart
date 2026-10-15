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
///   await txn.commit();
/// } catch (_) {
///   await txn.cancel();
///   rethrow;
/// }
/// ```
///
/// A transaction lives on the server connection, so it is lost if the
/// connection drops: later calls on it then fail with a [NotFoundError].
final class SurrealTransaction with SurrealQueryable {
  SurrealTransaction._(this._client, this._session, this.id);

  final Surreal _client;
  final Uuid? _session;

  /// The server's id for this transaction.
  final Uuid id;

  var _done = false;

  /// Whether [commit] or [cancel] has been called.
  bool get isDone => _done;

  /// Commits every change made in the transaction.
  Future<void> commit() async {
    _checkOpen();
    _done = true;
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
}
