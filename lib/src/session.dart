part of 'surreal.dart';

/// The default for the arguments of `use` that leaves the current value as
/// it is. Passing null instead clears the value.
const String _unchanged = '\u0000unchanged';

/// The calls that act on a session: selecting a namespace and database,
/// authentication, variables, live queries and transactions. Shared by the
/// client, which is the connection's default session, and every
/// [SurrealSession].
mixin SurrealSessionMethods on SurrealQueryable {
  Surreal get _client;

  /// The id of the attached session, or null for the default session.
  Uuid? get _sessionId;

  SessionState get _state;

  /// Throws when the session can no longer be used.
  void _checkOpen() {}

  /// Renews the session's tokens before they expire.
  _TokenRenewal get _renewal;

  /// Runs [call], which changes the session's authentication, with token
  /// renewal held off. See [_TokenRenewal.during].
  Future<T> _changingAuth<T>(Future<T> Function() call,
          {bool keepCredentials = false}) =>
      _renewal.during(call, keepCredentials: keepCredentials);

  @override
  Future<Object?> _call(String method, [List<Object?> params = const []]) =>
      _client._rpc(method, params, session: _sessionId);

  /// The namespace currently selected, if any.
  String? get namespace => _state.namespace;

  /// The database currently selected, if any.
  String? get database => _state.database;

  /// The access token in use, if the session is authenticated.
  String? get accessToken => _state.token;

  /// The access token and its refresh token, if the session is
  /// authenticated.
  Tokens? get tokens {
    final access = _state.token;
    if (access == null) return null;
    return Tokens(access: access, refresh: _state.refreshToken);
  }

  /// The variables defined with [set].
  Map<String, Object?> get variables => Map.unmodifiable(_state.variables);

  /// Selects the [namespace] and [database] for subsequent operations.
  ///
  /// An argument that is left out keeps its current value, and an argument
  /// passed as null clears it. Clearing the namespace clears the database
  /// too, so a database cannot be selected without a namespace.
  ///
  /// ```dart
  /// await db.use(namespace: 'app', database: 'main');
  /// await db.use(database: 'other'); // same namespace
  /// await db.use(namespace: null);   // clear both
  /// ```
  Future<void> use(
      {String? namespace = _unchanged, String? database = _unchanged}) async {
    final keepNamespace = identical(namespace, _unchanged);
    final keepDatabase = identical(database, _unchanged);
    if (!keepNamespace &&
        namespace == null &&
        database != null &&
        !keepDatabase) {
      throw const MissingNamespaceDatabaseError(
          'A database cannot be selected while clearing the namespace');
    }
    // A value that stays the same is sent as it is when it is known, so that
    // codecs without NONE (JSON) do not clear it, and as NONE otherwise.
    final clearNamespace = !keepNamespace && namespace == null;
    Object? currentNamespace = _state.namespace ?? none;
    Object? currentDatabase = _state.database ?? none;
    final unknown = (keepNamespace && currentNamespace is SurrealNone) ||
        (!clearNamespace && keepDatabase && currentDatabase is SurrealNone);
    if (unknown && !_client._canSendNone) {
      // NONE would arrive as null and clear the value, so ask the server
      // what it has selected and send that back.
      final [selected] = await query('RETURN [session::ns(), session::db()]');
      final [ns, db] = selected! as List<Object?>;
      if (currentNamespace is SurrealNone) currentNamespace = ns;
      if (currentDatabase is SurrealNone) currentDatabase = db;
    }
    await _call('use', [
      keepNamespace ? currentNamespace : namespace,
      clearNamespace
          ? null
          : keepDatabase
              ? currentDatabase
              : database,
    ]);
  }

  /// Signs up a new record access user and returns the issued tokens.
  Future<Tokens> signup(AccessRecordAuth auth) => _changingAuth(
      () async => _tokensFrom(await _call('signup', [auth.toJson()])));

  /// Signs in with the given credentials and returns the issued tokens.
  Future<Tokens> signin(AnyAuth auth) => _changingAuth(
      () async => _tokensFrom(await _call('signin', [auth.toJson()])));

  /// Authenticates the session with an existing access [token].
  ///
  /// Pass the [refreshToken] issued with it to let the client refresh the
  /// session: straight away when [token] has already expired or is
  /// rejected, and automatically before it expires.
  Future<void> authenticate(String token, {String? refreshToken}) =>
      _changingAuth(() async {
        final expiry = tokenExpiry(token);
        final expired =
            expiry != null && !expiry.isAfter(DateTime.now().toUtc());
        if (refreshToken != null && expired) {
          await _refresh(Tokens(access: token, refresh: refreshToken));
          return;
        }
        // The session takes both tokens at once, when the call succeeds.
        _state.expectTokens(token, refreshToken);
        try {
          await _call('authenticate', [token]);
        } on NotAllowedError {
          if (refreshToken == null) rethrow;
          await _refresh(Tokens(access: token, refresh: refreshToken));
          return;
        } finally {
          _state.expectTokens(null, null);
        }
      });

  /// Exchanges a refresh token for a new access token and refresh token, and
  /// authenticates the session with them. Uses the session's own [tokens]
  /// unless others are given.
  ///
  /// A refresh token can be used once: the server revokes it as it issues
  /// the new one. Needs SurrealDB 3.0 or later and an access method defined
  /// `WITH REFRESH`.
  Future<Tokens> refresh([Tokens? tokens]) =>
      _changingAuth(() => _refresh(tokens ?? this.tokens),
          keepCredentials: true);

  Future<Tokens> _refresh(Tokens? tokens) async {
    if (tokens?.refresh == null) {
      throw const AuthenticationError(
          'There is no refresh token to refresh the session with');
    }
    return _tokensFrom(await _call('refresh', [tokens!.toJson()]));
  }

  /// Revokes a refresh token so it can no longer be used. Uses the session's
  /// own [tokens] unless others are given. The session stays authenticated
  /// until its access token expires, but can no longer be refreshed.
  Future<void> revoke([Tokens? tokens]) => _changingAuth(() async {
        final current = tokens ?? this.tokens;
        final refreshToken = current?.refresh;
        if (refreshToken == null) {
          throw const AuthenticationError(
              'There is no refresh token to revoke');
        }
        await _call('revoke', [current!.toJson()]);
        if (_state.refreshToken == refreshToken) {
          _state.setTokens(_state.token, null);
        }
      }, keepCredentials: true);

  /// Invalidates the session, signing out.
  Future<void> invalidate() => _changingAuth(() => _call('invalidate'));

  /// Resets the session: signs out, clears the namespace, database and every
  /// variable, cancels its transactions and stops its live queries. The
  /// connection stays open.
  Future<void> reset() async {
    await _changingAuth(() => _call('reset'));
    // The server has stopped every live query of the session.
    await _client._disposeLiveQueries(_sessionId);
  }

  /// Returns the record associated with the current authentication, or null.
  Future<Map<String, dynamic>?> info() async {
    final result = await _call('info');
    return result as Map<String, dynamic>?;
  }

  /// Defines a session wide parameter that can be used in queries as `$key`.
  ///
  /// Over WebSocket the parameter lives in the server-side session and is
  /// set again after a reconnect, so every call sees it. Over HTTP, where
  /// each request is its own session, the client keeps it and binds it to
  /// every [query]. The other calls, such as [select] and [create], take no
  /// variables on the server, so over HTTP they run without it: use [query]
  /// when they depend on it, for example through table permissions.
  Future<void> set(String key, Object? value) async {
    await _call('let', [key, value]);
  }

  /// Removes a parameter previously defined with [set].
  Future<void> unset(String key) async {
    await _call('unset', [key]);
  }

  // ---------------------------------------------------------------------------
  // Live queries
  // ---------------------------------------------------------------------------

  /// Starts a live query on [resource] and returns a handle. Listen to the
  /// handle's `stream` for change notifications. When [diff] is true, each
  /// notification carries a set of JSON Patch operations instead of the record.
  ///
  /// The query is restarted, with a new id, if the connection drops and is
  /// re-established.
  Future<LiveQuery> live(Object resource, {bool diff = false}) async {
    final uuid = _asUuid(await _call('live', [_thing(resource), diff]));
    return _client._registerLive(uuid, _sessionId, resource, diff);
  }

  /// Subscribes to a live query that is already running on this session, for
  /// example one started with a `LIVE SELECT` statement in [query].
  ///
  /// The client does not know what the query selects, so it cannot restart
  /// it after a reconnect: its stream then gets a [LiveQueryLostError] and
  /// closes. Use [live] for a query that survives reconnects.
  LiveQuery liveOf(Uuid id) {
    _checkOpen();
    final engine = _client._engine;
    // Without a connection there is no session for the query to run in, and
    // nothing would ever arrive on, or close, its stream.
    if (engine == null || engine.status != ConnectionStatus.connected) {
      throw const ConnectionUnavailableError();
    }
    if (!engine.supportsLiveQueries) {
      throw const UnsupportedFeatureError('live');
    }
    // The handle for a query that is already registered is shared, so that
    // killing one does not leave another open.
    final existing = _client._liveByUuid[id.toString()];
    if (existing != null) return existing.query;
    return _client._registerLive(id, _sessionId, null, false);
  }

  /// Stops the live query with the given [id].
  Future<void> kill(Uuid id) async {
    await _call('kill', [id]);
    // A kill stops only a query of this session, so a query registered by
    // another session keeps its handle.
    final registration = _client._liveByUuid[id.toString()];
    if (registration != null && registration.session == _sessionId) {
      _client._liveByUuid.remove(id.toString());
      await registration.query.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions and transactions
  // ---------------------------------------------------------------------------

  /// Starts an interactive transaction in this session. See
  /// [SurrealTransaction]. Needs the WebSocket engine and SurrealDB 3.0 or
  /// later.
  Future<SurrealTransaction> beginTransaction() async {
    _client._requireSessions('transactions');
    final id = _asUuid(await _call('begin'));
    return SurrealTransaction._(_client, _sessionId, id);
  }

  /// Starts a new session on the same connection that begins as a copy of
  /// this one: the same namespace, database, variables and authentication.
  /// From then on the two are independent.
  ///
  /// The fork gets the access token but not the refresh token, which can be
  /// used only once. It renews by signing in again when this session has
  /// the credentials to (those given to `connect`), and otherwise stays
  /// authenticated until the access token expires.
  Future<SurrealSession> forkSession() async {
    _checkOpen();
    return _client._attachSession(
        copyOf: _state.copy(), credentials: _renewal.credentials);
  }
}

/// A session attached to the client's connection, alongside the default
/// session that the client itself represents.
///
/// Each session has its own namespace, database, variables, authentication,
/// live queries and transactions, so one connection can serve several users
/// or tenants at once. Create one with [Surreal.newSession] or
/// [SurrealSessionMethods.forkSession], and [close] it when done. Sessions
/// need the WebSocket engine and SurrealDB 3.0 or later.
///
/// Attached sessions are attached again and replayed after a reconnect.
final class SurrealSession with SurrealQueryable, SurrealSessionMethods {
  SurrealSession._(this._client, this.id, this._state);

  @override
  final Surreal _client;

  @override
  final SessionState _state;

  /// The id of this session on the server.
  final Uuid id;

  @override
  late final _TokenRenewal _renewal = _TokenRenewal(_client, _state, id);

  var _closed = false;

  @override
  Uuid? get _sessionId => id;

  /// Whether [close] has been called, or the client closed.
  bool get isClosed => _closed;

  @override
  void _checkOpen() {
    if (_closed) throw InvalidSessionError(id);
  }

  @override
  Future<Object?> _call(String method, [List<Object?> params = const []]) {
    _checkOpen();
    return super._call(method, params);
  }

  /// Detaches the session from the server, which stops its live queries and
  /// cancels its transactions.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _renewal.stop();
    _client._attached.remove(id);
    _client._engine?.untrackSession(id);
    await _client._disposeLiveQueries(id);
    try {
      await _client._rpc('detach', const [], session: id);
    } on ConnectionUnavailableError {
      // The connection is down. Its sessions went with it, and this one is
      // no longer tracked, so it is not attached again.
    }
  }

  @override
  String toString() => 'SurrealSession($id)';
}
