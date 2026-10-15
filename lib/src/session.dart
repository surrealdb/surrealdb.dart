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

  /// Called before a call that replaces the session's authentication.
  void _authChanging() {}

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
    await _call('use', [
      keepNamespace ? (_state.namespace ?? none) : namespace,
      clearNamespace
          ? null
          : keepDatabase
              ? (_state.database ?? none)
              : database,
    ]);
  }

  /// Signs up a new record access user and returns the issued tokens.
  Future<Tokens> signup(AccessRecordAuth auth) async {
    _authChanging();
    return _tokensFrom(await _call('signup', [auth.toJson()]));
  }

  /// Signs in with the given credentials and returns the issued tokens.
  Future<Tokens> signin(AnyAuth auth) async {
    _authChanging();
    return _tokensFrom(await _call('signin', [auth.toJson()]));
  }

  /// Authenticates the session with an existing access [token].
  ///
  /// Pass the [refreshToken] issued with it to let the client refresh the
  /// session: straight away when [token] has already expired or is
  /// rejected, and automatically before it expires.
  Future<void> authenticate(String token, {String? refreshToken}) async {
    _authChanging();
    final expiry = tokenExpiry(token);
    final expired = expiry != null && !expiry.isAfter(DateTime.now().toUtc());
    if (refreshToken != null && expired) {
      await refresh(Tokens(access: token, refresh: refreshToken));
      return;
    }
    try {
      await _call('authenticate', [token]);
    } on NotAllowedError {
      if (refreshToken == null) rethrow;
      await refresh(Tokens(access: token, refresh: refreshToken));
      return;
    }
    _state.setTokens(token, refreshToken);
  }

  /// Exchanges a refresh token for a new access token and refresh token, and
  /// authenticates the session with them. Uses the session's own [tokens]
  /// unless others are given.
  ///
  /// A refresh token can be used once: the server revokes it as it issues
  /// the new one. Needs SurrealDB 3.0 or later and an access method defined
  /// `WITH REFRESH`.
  Future<Tokens> refresh([Tokens? tokens]) async {
    final current = tokens ?? this.tokens;
    if (current?.refresh == null) {
      throw const AuthenticationError(
          'There is no refresh token to refresh the session with');
    }
    return _tokensFrom(await _call('refresh', [current!.toJson()]));
  }

  /// Revokes a refresh token so it can no longer be used. Uses the session's
  /// own [tokens] unless others are given. The session stays authenticated
  /// until its access token expires, but can no longer be refreshed.
  Future<void> revoke([Tokens? tokens]) async {
    final current = tokens ?? this.tokens;
    final refreshToken = current?.refresh;
    if (refreshToken == null) {
      throw const AuthenticationError('There is no refresh token to revoke');
    }
    await _call('revoke', [current!.toJson()]);
    if (_state.refreshToken == refreshToken) {
      _state.setTokens(_state.token, null);
    }
  }

  /// Invalidates the session, signing out.
  Future<void> invalidate() async {
    _authChanging();
    await _call('invalidate');
  }

  /// Resets the session: signs out, clears the namespace, database and every
  /// variable, cancels its transactions and stops its live queries. The
  /// connection stays open.
  Future<void> reset() async {
    _authChanging();
    await _call('reset');
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
  /// set again after a reconnect. Over HTTP, where each request is its own
  /// session, the client keeps it and binds it to every query.
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
    final engine = _client._engine;
    if (engine == null) throw const ConnectionUnavailableError();
    if (!engine.supportsLiveQueries) {
      throw const UnsupportedFeatureError('live');
    }
    return _client._registerLive(id, _sessionId, null, false);
  }

  /// Stops the live query with the given [id].
  Future<void> kill(Uuid id) async {
    final registration = _client._liveByUuid.remove(id.toString());
    await _call('kill', [id]);
    await registration?.query.dispose();
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
  Future<SurrealSession> forkSession() =>
      _client._attachSession(copyOf: _state.copy());
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

  var _closed = false;

  @override
  Uuid? get _sessionId => id;

  /// Whether [close] has been called, or the client closed.
  bool get isClosed => _closed;

  @override
  Future<Object?> _call(String method, [List<Object?> params = const []]) {
    if (_closed) throw InvalidSessionError(id);
    return super._call(method, params);
  }

  /// Detaches the session from the server, which stops its live queries and
  /// cancels its transactions.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client._attached.remove(id);
    _client._engine?.untrackSession(id);
    await _client._disposeLiveQueries(id);
    await _client._rpc('detach', const [], session: id);
  }

  @override
  String toString() => 'SurrealSession($id)';
}
