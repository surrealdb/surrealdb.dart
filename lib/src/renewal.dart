part of 'surreal.dart';

/// Renews one session's access token before it expires: with its refresh
/// token when it has one, otherwise by signing in again with [credentials].
/// The client and every attached session have one each.
final class _TokenRenewal {
  _TokenRenewal(this._client, this._state, this._sessionId, {this.onError});

  final Surreal _client;
  final SessionState _state;
  final Uuid? _sessionId;

  /// Told about a renewal that failed.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// The credentials to sign in with again when there is no refresh token.
  AnyAuth? credentials;

  Timer? _timer;
  Future<void>? _renewing;
  var _stopped = false;

  /// Completes once a renewal under way, if any, has finished. A call that
  /// replaces the authentication waits for this, so that the renewal's
  /// result cannot arrive after, and undo, the newer authentication.
  Future<void> settled() async {
    final renewing = _renewing;
    if (renewing != null) await renewing;
  }

  /// Plans the next renewal for the current tokens.
  void reschedule() {
    _timer?.cancel();
    _timer = null;
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
    if (_state.refreshToken == null && credentials == null) return;
    final expiry = tokenExpiry(token);
    if (expiry == null) return;
    final delay = after ?? renewalDelay(expiry, _client._tokenExpiryMargin);
    _timer = Timer(delay, () => _renew(token, expiry));
  }

  Future<void> _renew(String token, DateTime expiry) async {
    _timer = null;
    // The tokens changed since this renewal was scheduled.
    if (_stopped || _state.token != token || _client._engine == null) return;
    final done = Completer<void>();
    _renewing = done.future;
    try {
      final credentials = this.credentials;
      final refreshToken = _state.refreshToken;
      if (refreshToken != null) {
        await _client._rpc(
            'refresh',
            [
              Tokens(access: token, refresh: refreshToken).toJson(),
            ],
            session: _sessionId);
      } else if (credentials != null) {
        await _client._rpc('signin', [credentials.toJson()],
            session: _sessionId);
      }
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
      if (_state.token != token) return;
      if (error is NotAllowedError) {
        // The refresh token or credentials were rejected, so retrying will
        // not help. The session keeps its access token until it expires.
        _state.setTokens(token, null);
        return;
      }
      // Try again shortly while the token is still valid, for example once
      // a dropped connection is back.
      if (expiry.isAfter(DateTime.now().toUtc())) {
        _schedule(after: const Duration(seconds: 5));
      }
    } finally {
      _renewing = null;
      done.complete();
    }
  }
}
