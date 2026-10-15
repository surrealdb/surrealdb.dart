part of 'surreal.dart';

/// Renews one session's access token before it expires: with its refresh
/// token when it has one, otherwise by signing in again with [credentials].
/// With neither, the session is signed out when the access token expires.
/// The client and every attached session have one each.
final class _TokenRenewal {
  _TokenRenewal(this._client, this._state, this._sessionId, {this.onError});

  final Surreal _client;
  final SessionState _state;
  final Uuid? _sessionId;

  /// Told about a renewal that failed.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// The credentials to sign in with again when there is no refresh token,
  /// as sent. A copy, so that changes to the caller's objects since do not
  /// change who signs in.
  Map<String, Object?>? credentials;

  Timer? _timer;

  /// How many renewals in a row have failed, for backing off.
  var _failures = 0;
  Future<void>? _renewing;
  var _stopped = false;

  /// How many calls that change the authentication are under way.
  var _authCalls = 0;

  /// Completes when the last call to change the authentication is done.
  Future<void> _queue = Future.value();

  /// Runs [call], which changes the session's authentication, with renewal
  /// held off: a renewal under way finishes first, and none starts until
  /// [call] is done, so a renewal can never run alongside it and undo it.
  /// Unless [keepCredentials], the credentials for signing in again are
  /// forgotten, since they belong to the authentication being replaced.
  ///
  /// Calls run one at a time, in order, so each sees the session the last
  /// one left. One that fails leaves the authentication as it was, so its
  /// credentials are kept.
  Future<T> during<T>(Future<T> Function() call,
      {bool keepCredentials = false}) async {
    _authCalls++;
    _timer?.cancel();
    _timer = null;
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    try {
      await previous;
      final renewing = _renewing;
      if (renewing != null) await renewing;
      final kept = credentials;
      if (!keepCredentials) credentials = null;
      try {
        return await call();
      } catch (_) {
        credentials ??= kept;
        rethrow;
      }
    } finally {
      done.complete();
      _authCalls--;
      if (_authCalls == 0) _schedule();
    }
  }

  /// Plans the next renewal for the current tokens.
  void reschedule() {
    _timer?.cancel();
    _timer = null;
    _failures = 0;
    _schedule();
  }

  /// Cancels the planned renewal and forgets the credentials, until the
  /// tokens change again.
  void cancel() {
    credentials = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Stops renewing, for good.
  void stop() {
    _stopped = true;
    cancel();
  }

  void _schedule({Duration? after}) {
    final token = _state.token;
    if (_stopped || !_client._renewTokens || token == null) return;
    if (_authCalls > 0) return;
    final expiry = tokenExpiry(token);
    if (expiry == null) return;
    _timer?.cancel();
    if (_state.refreshToken == null && credentials == null) {
      final left = expiry.difference(DateTime.now().toUtc());
      _timer = Timer(left.isNegative ? Duration.zero : left, () {
        _timer = null;
        if (_state.token == token) _state.setTokens(null, null);
      });
      return;
    }
    final delay = after ?? renewalDelay(expiry, _client._tokenExpiryMargin);
    _timer = Timer(delay, () => _renew(token, expiry));
  }

  /// Selects [namespace] and [database] again, as replay values, when
  /// signing in again selected others: what the new token names.
  Future<void> _selectAgain(Object? namespace, Object? database) async {
    if (_state.replayNamespace == namespace &&
        _state.replayDatabase == database) {
      return;
    }
    final session =
        _sessionId == null ? _client : _client._attached[_sessionId];
    try {
      await session?._use(
        namespace is SurrealNone ? _unchanged : namespace as String?,
        database is SurrealNone ? _unchanged : database as String?,
      );
    } on ResponseError {
      // Refused, so the session stays as signing in left it, which is what
      // it reports.
    } on SurrealError {
      // The connection is down, or was dropped because the call timed out.
      // Keep the selection wanted, which the reconnect then makes.
      _state.applyUse([namespace, database]);
    }
  }

  /// Schedules the next attempt at a renewal that did not happen, backing
  /// off.
  void _retry() {
    final delay = Duration(seconds: 5 << _failures.clamp(0, 4));
    _failures++;
    _schedule(after: delay);
  }

  Future<void> _renew(String token, DateTime expiry) async {
    _timer = null;
    // The tokens changed since this renewal was scheduled, or are changing.
    if (_stopped || _state.token != token || _client._engine == null) return;
    if (_authCalls > 0) return;
    final done = Completer<void>();
    _renewing = done.future;
    try {
      final credentials = this.credentials;
      final refreshToken = _state.refreshToken;
      final namespace = _state.replayNamespace;
      final database = _state.replayDatabase;
      if (refreshToken != null) {
        await _client._rpc(
            'refresh',
            [
              Tokens(access: token, refresh: refreshToken).toJson(),
            ],
            session: _sessionId);
      } else if (credentials != null) {
        await _client._rpc('signin', [credentials], session: _sessionId);
      }
      await _selectAgain(namespace, database);
      // A server may give the same token back, which renews nothing and
      // schedules nothing.
      if (_state.token == token && _timer == null) _retry();
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
      if (_state.token != token) return;
      if (rejectsAuthentication(error)) {
        // The refresh token or credentials were rejected, so retrying will
        // not help. The session keeps its access token until it expires,
        // and is signed out then.
        if (_state.refreshToken != null) {
          _state.setTokens(token, null);
        } else {
          credentials = null;
        }
        // Signs out at expiry, unless the credentials can still renew it.
        _schedule();
        return;
      }
      // Try again, backing off, for example once a dropped connection is
      // back. This goes on after the access token expires, as the refresh
      // token or credentials may still work.
      _retry();
    } finally {
      _renewing = null;
      done.complete();
    }
  }
}
