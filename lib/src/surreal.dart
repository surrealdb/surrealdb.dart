import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cbor/codec.dart';
import 'engine/engine.dart';
import 'engine/http_engine.dart';
import 'engine/session_state.dart';
import 'engine/websocket_engine.dart';
import 'errors.dart';
import 'internal/jwt.dart';
import 'live_query.dart';
import 'protocol/codecs.dart';
import 'types/auth.dart';
import 'types/connection.dart';
import 'types/live.dart';
import 'types/patch.dart';
import 'value/value.dart';

/// The lowest SurrealDB server version this client accepts.
const String minimumServerVersion = '1.4.2';

/// The first SurrealDB server version this client no longer accepts.
const String maximumServerVersion = '5.0.0';

class _LiveRegistration {
  _LiveRegistration(this.query, this.resource, this.diff);

  final LiveQuery query;

  /// What the live query selects from, or null for a query attached with
  /// `liveOf`, which the client cannot restart.
  final Object? resource;
  final bool diff;
}

/// The default for the arguments of [Surreal.use] that leaves the current
/// value as it is. Passing null instead clears the value.
const String _unchanged = '\u0000unchanged';

/// A client for a single SurrealDB connection.
///
/// Create an instance, [connect] to a server, select a namespace and database
/// with [use], authenticate, then run queries and CRUD operations. Live queries
/// are returned as [LiveQuery] handles whose change notifications arrive on a
/// [Stream].
///
/// ```dart
/// final db = Surreal();
/// await db.connect('ws://127.0.0.1:8000/rpc');
/// await db.use(namespace: 'test', database: 'test');
/// await db.signin(const RootAuth(username: 'root', password: 'root'));
/// final created = await db.create('person', {'name': 'Tobie'});
/// ```
class Surreal {
  Engine? _engine;
  Uri? _url;
  http.Client? _httpClient;
  StreamSubscription<ConnectionStatus>? _statusSubscription;
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  late final SessionState _session = SessionState()
    ..onTokensChanged = _onTokensChanged;
  String? _version;

  // Token renewal.
  var _renewTokens = true;
  var _tokenExpiryMargin = const Duration(seconds: 60);
  AnyAuth? _renewWith;
  Timer? _renewalTimer;

  /// Completes when the automatic renewal under way, if any, has finished.
  Future<void>? _renewing;
  final _authController = StreamController<Tokens?>.broadcast();

  final Map<String, _LiveRegistration> _liveByUuid = {};
  StreamSubscription<LiveMessage>? _liveSubscription;

  /// The namespace currently selected, if any.
  String? get namespace => _session.namespace;

  /// The database currently selected, if any.
  String? get database => _session.database;

  /// The access token in use, if the session is authenticated.
  String? get accessToken => _session.token;

  /// The access token and its refresh token, if the session is
  /// authenticated.
  Tokens? get tokens {
    final access = _session.token;
    if (access == null) return null;
    return Tokens(access: access, refresh: _session.refreshToken);
  }

  /// Emits the new [tokens] whenever they change: after signing in, a
  /// refresh, an automatic renewal or a reconnect that had to refresh. Emits
  /// null when the session loses its authentication. A failed automatic
  /// renewal is delivered as an error.
  Stream<Tokens?> get authChanges => _authController.stream;

  /// The server version, available after [connect] with a version check or a
  /// call to [version].
  String? get serverVersion => _version;

  /// The current connection status.
  ConnectionStatus get status =>
      _engine?.status ?? ConnectionStatus.disconnected;

  /// Whether there is an open connection.
  bool get isConnected => status == ConnectionStatus.connected;

  /// Emits whenever the connection status changes. The stream outlives any
  /// single connection, so a listener keeps receiving updates across [close]
  /// and a later [connect].
  Stream<ConnectionStatus> get statusChanges => _statusController.stream;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Connects to the server at [url]. The scheme selects the engine: `ws` and
  /// `wss` use the WebSocket engine, `http` and `https` use the HTTP engine.
  ///
  /// Calling [connect] on a client that is already connected closes the
  /// existing connection first. A client can be connected again after [close].
  Future<void> connect(String url,
      {ConnectOptions options = const ConnectOptions()}) async {
    if (_engine != null) await close();
    final uri = Uri.parse(url);
    _httpClient = http.Client();
    final engine = _engineFor(uri, options);
    _engine = engine;
    _url = uri;
    engine.onReconnect = _restartLiveQueries;
    engine.onAuthenticationLost = (_) => _session.setTokens(null, null);
    _renewTokens = options.renewTokens;
    _tokenExpiryMargin = options.tokenExpiryMargin;
    _liveSubscription = engine.liveNotifications.listen(_routeLive);
    _statusSubscription = engine.statusChanges.listen(_statusController.add);

    await engine.open(uri, timeout: options.timeout);

    if (options.versionCheck) {
      try {
        await _checkVersion();
      } catch (_) {
        await close();
        rethrow;
      }
      // Servers before 3.0 have no set type and reject its CBOR tag.
      final codec = engine.codec;
      final major = _parseVersion(_version ?? '')?.first;
      if (codec is CborCodec &&
          !codec.setsAsArrays &&
          major != null &&
          major < 3) {
        engine.codec = const CborCodec(setsAsArrays: true);
      }
    }
    if (options.namespace != null || options.database != null) {
      await use(
        namespace: options.namespace ?? _unchanged,
        database: options.database ?? _unchanged,
      );
    }
    final credentials = options.authentication;
    if (credentials != null) {
      // Without a refresh token, renewal signs in again with these.
      _renewWith = credentials;
      await _rpc('signin', [credentials.toJson()]);
    } else if (options.token != null) {
      await authenticate(options.token!, refreshToken: options.refreshToken);
    }
  }

  Engine _engineFor(Uri uri, ConnectOptions options) {
    final codec = options.codec ?? codecForFormat(options.format);
    switch (uri.scheme) {
      case 'ws':
      case 'wss':
        return WebSocketEngine(
          codec,
          reconnect: options.reconnect,
          requestTimeout: options.requestTimeout,
          session: _session,
        );
      case 'http':
      case 'https':
        return HttpEngine(
          codec,
          client: _httpClient!,
          requestTimeout: options.requestTimeout,
          session: _session,
        );
      default:
        throw UnsupportedEngineError(uri.scheme);
    }
  }

  /// Closes the connection and releases resources. Active live queries are
  /// closed. The client can be connected again with [connect].
  Future<void> close() async {
    await _liveSubscription?.cancel();
    _liveSubscription = null;
    final registrations = List.of(_liveByUuid.values);
    _liveByUuid.clear();
    for (final reg in registrations) {
      await reg.query.dispose();
    }
    final engine = _engine;
    _engine = null;
    await engine?.close();
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    if (engine != null) _statusController.add(ConnectionStatus.disconnected);
    _httpClient?.close();
    _httpClient = null;
    _renewWith = null;
    _renewalTimer?.cancel();
    _renewalTimer = null;
    _session.clear();
    _version = null;
  }

  /// Returns the server version string, for example `2.1.0`.
  Future<String> version() async {
    final result = await _rpc('version');
    final version =
        result is Map ? result['version']?.toString() : result?.toString();
    _version = version;
    return version ?? '';
  }

  /// Checks that the server is reachable and healthy. Throws on failure.
  Future<void> health() async {
    final base = _httpBase();
    final response = await _http.get(base.replace(path: '/health'));
    if (response.statusCode != 200) {
      throw HttpConnectionError(
        'Health check failed with status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  /// Fails with [UnsupportedVersionError] unless the server version is at
  /// least [minimumServerVersion] and below [maximumServerVersion]. A
  /// pre-release counts as its release, so `5.0.0-alpha` is rejected and
  /// `3.4.0-nightly` is accepted.
  Future<void> _checkVersion() async {
    final version = await this.version();
    if (!isSupportedServerVersion(version)) {
      throw UnsupportedVersionError(
          version, minimumServerVersion, maximumServerVersion);
    }
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  /// Whether a `use` call can carry NONE to keep a value. A JSON WebSocket
  /// cannot; over HTTP the client applies `use` itself.
  bool get _canSendNone {
    final engine = _engine;
    return engine is! WebSocketEngine || engine.codec is CborCodec;
  }

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
    Object? currentNamespace = _session.namespace ?? none;
    Object? currentDatabase = _session.database ?? none;
    final unknown = (keepNamespace && currentNamespace is SurrealNone) ||
        (!clearNamespace && keepDatabase && currentDatabase is SurrealNone);
    if (unknown && !_canSendNone) {
      // NONE would arrive as null and clear the value, so ask the server
      // what it has selected and send that back.
      final [selected] = await query('RETURN [session::ns(), session::db()]');
      final [ns, db] = selected! as List<Object?>;
      if (currentNamespace is SurrealNone) currentNamespace = ns;
      if (currentDatabase is SurrealNone) currentDatabase = db;
    }
    await _rpc('use', [
      keepNamespace ? currentNamespace : namespace,
      clearNamespace
          ? null
          : keepDatabase
              ? currentDatabase
              : database,
    ]);
  }

  /// Called before a call that replaces the session's authentication. Waits
  /// for an automatic renewal that is under way, so that its result cannot
  /// arrive after, and undo, the newer authentication.
  Future<void> _authChanging() async {
    _renewWith = null;
    await _renewalSettled();
  }

  Future<void> _renewalSettled() async {
    final renewing = _renewing;
    if (renewing != null) await renewing;
  }

  /// Signs up a new record access user and returns the issued tokens.
  Future<Tokens> signup(AccessRecordAuth auth) async {
    await _authChanging();
    return _tokensFrom(await _rpc('signup', [auth.toJson()]));
  }

  /// Signs in with the given credentials and returns the issued tokens.
  Future<Tokens> signin(AnyAuth auth) async {
    await _authChanging();
    return _tokensFrom(await _rpc('signin', [auth.toJson()]));
  }

  /// Authenticates the current session with an existing access [token].
  ///
  /// Pass the [refreshToken] issued with it to let the client refresh the
  /// session: straight away when [token] has already expired or is
  /// rejected, and automatically before it expires.
  Future<void> authenticate(String token, {String? refreshToken}) async {
    await _authChanging();
    final expiry = tokenExpiry(token);
    final expired = expiry != null && !expiry.isAfter(DateTime.now().toUtc());
    if (refreshToken != null && expired) {
      await refresh(Tokens(access: token, refresh: refreshToken));
      return;
    }
    try {
      await _rpc('authenticate', [token]);
    } on NotAllowedError {
      if (refreshToken == null) rethrow;
      await refresh(Tokens(access: token, refresh: refreshToken));
      return;
    }
    _session.setTokens(token, refreshToken);
  }

  /// Exchanges a refresh token for a new access token and refresh token, and
  /// authenticates the session with them. Uses the session's own [tokens]
  /// unless others are given.
  ///
  /// A refresh token can be used once: the server revokes it as it issues
  /// the new one. Needs SurrealDB 3.0 or later and an access method defined
  /// `WITH REFRESH`.
  Future<Tokens> refresh([Tokens? tokens]) async {
    await _renewalSettled();
    final current = tokens ?? this.tokens;
    if (current?.refresh == null) {
      throw const AuthenticationError(
          'There is no refresh token to refresh the session with');
    }
    return _tokensFrom(await _rpc('refresh', [current!.toJson()]));
  }

  /// Revokes a refresh token so it can no longer be used. Uses the session's
  /// own [tokens] unless others are given. The session stays authenticated
  /// until its access token expires, but can no longer be refreshed.
  Future<void> revoke([Tokens? tokens]) async {
    await _renewalSettled();
    final current = tokens ?? this.tokens;
    final refreshToken = current?.refresh;
    if (refreshToken == null) {
      throw const AuthenticationError('There is no refresh token to revoke');
    }
    await _rpc('revoke', [current!.toJson()]);
    if (_session.refreshToken == refreshToken) {
      _session.setTokens(_session.token, null);
    }
  }

  /// Invalidates the current session, signing out.
  Future<void> invalidate() async {
    await _authChanging();
    await _rpc('invalidate');
  }

  /// Reschedules renewal and tells listeners whenever the tokens change.
  void _onTokensChanged() {
    _renewalTimer?.cancel();
    _renewalTimer = null;
    if (!_authController.isClosed) _authController.add(tokens);
    _scheduleRenewal();
  }

  /// Renews the session [_tokenExpiryMargin] before its access token
  /// expires: with the refresh token when there is one, otherwise by signing
  /// in again with the credentials given to [connect].
  void _scheduleRenewal({Duration? after}) {
    final token = _session.token;
    if (!_renewTokens || token == null) return;
    if (_session.refreshToken == null && _renewWith == null) return;
    final expiry = tokenExpiry(token);
    if (expiry == null) return;
    final delay = after ?? renewalDelay(expiry, _tokenExpiryMargin);
    _renewalTimer = Timer(delay, () => _renew(token, expiry));
  }

  Future<void> _renew(String token, DateTime expiry) async {
    _renewalTimer = null;
    // The tokens changed since this renewal was scheduled.
    if (_session.token != token || _engine == null) return;
    final done = Completer<void>();
    _renewing = done.future;
    try {
      final credentials = _renewWith;
      final refreshToken = _session.refreshToken;
      if (refreshToken != null) {
        await _rpc('refresh', [
          Tokens(access: token, refresh: refreshToken).toJson(),
        ]);
      } else if (credentials != null) {
        await _rpc('signin', [credentials.toJson()]);
      }
    } catch (error, stackTrace) {
      if (!_authController.isClosed) {
        _authController.addError(error, stackTrace);
      }
      if (_session.token != token) return;
      if (error is NotAllowedError) {
        // The refresh token or credentials were rejected, so retrying will
        // not help. The session keeps its access token until it expires.
        _session.setTokens(token, null);
        return;
      }
      // Try again shortly while the token is still valid, for example once
      // a dropped connection is back.
      if (expiry.isAfter(DateTime.now().toUtc())) {
        _scheduleRenewal(after: const Duration(seconds: 5));
      }
    } finally {
      _renewing = null;
      done.complete();
    }
  }

  /// Resets the session: signs out, clears the namespace, database and every
  /// variable, and stops the session's live queries. The connection stays
  /// open.
  Future<void> reset() async {
    await _authChanging();
    await _rpc('reset');
    // The server has stopped every live query of the session.
    final registrations = List.of(_liveByUuid.values);
    _liveByUuid.clear();
    for (final registration in registrations) {
      await registration.query.dispose();
    }
  }

  /// Returns the record associated with the current authentication, or null.
  Future<Map<String, dynamic>?> info() async {
    final result = await _rpc('info');
    return result as Map<String, dynamic>?;
  }

  /// Defines a session wide parameter that can be used in queries as `$key`.
  ///
  /// Over WebSocket the parameter lives in the server-side session and is
  /// set again after a reconnect. Over HTTP, where each request is its own
  /// session, the client keeps it and binds it to every query.
  Future<void> set(String key, Object? value) async {
    await _rpc('let', [key, value]);
  }

  /// Removes a parameter previously defined with [set].
  Future<void> unset(String key) async {
    await _rpc('unset', [key]);
  }

  // ---------------------------------------------------------------------------
  // Query
  // ---------------------------------------------------------------------------

  /// Runs a SurrealQL query and returns the result of each statement in order.
  /// If any statement fails, throws the [ServerError] for the first failure,
  /// with its kind, details and [ServerError.statementIndex].
  ///
  /// Bind parameters by referencing them as `$name` in [query] and passing the
  /// values in [bindings].
  Future<List<Object?>> query(String query,
      {Map<String, Object?>? bindings}) async {
    final statements = await queryRaw(query, bindings: bindings);
    final results = <Object?>[];
    for (final (index, statement) in statements.indexed) {
      if (statement['status'] != 'OK') {
        throw ServerError.fromStatement(statement, index: index);
      }
      results.add(statement['result']);
    }
    return results;
  }

  /// Runs a SurrealQL query and returns the raw status objects for each
  /// statement, without throwing on a failed statement. Each entry has a
  /// `status`, `time`, and `result`.
  Future<List<Map<String, dynamic>>> queryRaw(String query,
      {Map<String, Object?>? bindings}) async {
    final result = await _rpc('query', [query, bindings ?? const {}]);
    return (result as List).cast<Map<String, dynamic>>();
  }

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  /// Selects records. A record id returns a single record or null, a table or
  /// range returns a list.
  Future<dynamic> select(Object resource) => _rpc('select', [_thing(resource)]);

  /// Creates a record. [data] is the record content.
  Future<dynamic> create(Object resource, [Object? data]) =>
      _rpc('create', [_thing(resource), if (data != null) data]);

  /// Inserts one record or a list of records into [table].
  Future<dynamic> insert(Object table, Object data) =>
      _rpc('insert', [_thing(table), data]);

  /// Inserts one or more graph edges into [table].
  Future<dynamic> insertRelation(Object table, Object data) =>
      _rpc('insert_relation', [_thing(table), data]);

  /// Replaces the content of the matching records with [data].
  Future<dynamic> update(Object resource, Object data) =>
      _rpc('update', [_thing(resource), data]);

  /// Creates the record if it is missing, otherwise replaces its content.
  Future<dynamic> upsert(Object resource, Object data) =>
      _rpc('upsert', [_thing(resource), data]);

  /// Merges [data] into the matching records, leaving other fields untouched.
  Future<dynamic> merge(Object resource, Object data) =>
      _rpc('merge', [_thing(resource), data]);

  /// Applies a list of JSON Patch operations to the matching records. When
  /// [diff] is true the server returns the applied patches instead of the
  /// records.
  Future<dynamic> patch(Object resource, List<Patch> patches,
          {bool diff = false}) =>
      _rpc('patch', [
        _thing(resource),
        [for (final patch in patches) patch.toJson()],
        diff,
      ]);

  /// Deletes the matching records and returns them.
  Future<dynamic> delete(Object resource) => _rpc('delete', [_thing(resource)]);

  /// Creates a graph edge from [from] to [to] through the [edge] table or
  /// record, optionally carrying [data].
  Future<dynamic> relate(Object from, Object edge, Object to, [Object? data]) =>
      _rpc('relate', [
        _thing(from),
        _thing(edge),
        _thing(to),
        if (data != null) data,
      ]);

  /// Runs a built in or user defined function and returns its result.
  Future<dynamic> run(String name, {String? version, List<Object?>? args}) =>
      _rpc('run', [name, version, args ?? const []]);

  // ---------------------------------------------------------------------------
  // Live queries
  // ---------------------------------------------------------------------------

  /// Starts a live query on [resource] and returns a handle. Listen to the
  /// handle's `stream` for change notifications. When [diff] is true, each
  /// notification carries a set of JSON Patch operations instead of the record.
  Future<LiveQuery> live(Object resource, {bool diff = false}) async {
    final uuid = _asUuid(await _rpc('live', [_thing(resource), diff]));
    final query = LiveQuery(uuid, _killLive);
    _liveByUuid[uuid.toString()] = _LiveRegistration(query, resource, diff);
    return query;
  }

  /// Subscribes to a live query that is already running on this session, for
  /// example one started with a `LIVE SELECT` statement in [query].
  ///
  /// The client does not know what the query selects, so it cannot restart
  /// it after a reconnect: its stream then gets a [LiveQueryLostError] and
  /// closes. Use [live] for a query that survives reconnects.
  LiveQuery liveOf(Uuid id) {
    final engine = _engine;
    if (engine == null) throw const ConnectionUnavailableError();
    if (!engine.supportsLiveQueries) {
      throw const UnsupportedFeatureError('live');
    }
    // The handle for a query that is already registered is shared, so that
    // killing one does not leave another open.
    final existing = _liveByUuid[id.toString()];
    if (existing != null) return existing.query;
    final query = LiveQuery(id, _killLive);
    _liveByUuid[id.toString()] = _LiveRegistration(query, null, false);
    return query;
  }

  /// Stops the live query with the given [id].
  Future<void> kill(Uuid id) async {
    final registration = _liveByUuid.remove(id.toString());
    await _rpc('kill', [id]);
    await registration?.query.dispose();
  }

  Future<void> _killLive(LiveQuery query) async {
    _liveByUuid.remove(query.id.toString());
    await _rpc('kill', [query.id]);
    await query.dispose();
  }

  void _routeLive(LiveMessage message) {
    _liveByUuid[message.queryId.toString()]?.query.emit(message);
  }

  /// Starts every registered live query again after a reconnect. Each query
  /// is restarted on its own: one that fails keeps its registration, receives
  /// the error on its stream, and is tried again on the next reconnect.
  Future<void> _restartLiveQueries() async {
    for (final entry in _liveByUuid.entries.toList()) {
      final oldId = entry.key;
      final registration = entry.value;
      final resource = registration.resource;
      if (resource == null) {
        // Attached with liveOf, so there is nothing to restart it from.
        _liveByUuid.remove(oldId);
        registration.query.emitError(LiveQueryLostError(registration.query.id));
        await registration.query.dispose();
        continue;
      }
      final Uuid uuid;
      try {
        uuid = _asUuid(await _rpc('live', [
          _thing(resource),
          registration.diff,
        ]));
      } catch (error, stackTrace) {
        registration.query.emitError(error, stackTrace);
        continue;
      }
      if (_liveByUuid.remove(oldId) == null) {
        // Killed while the restart was in flight, so stop the new query too.
        unawaited(_rpc('kill', [uuid]).then((_) {}, onError: (_) {}));
        continue;
      }
      registration.query.rebind(uuid);
      _liveByUuid[uuid.toString()] = registration;
    }
  }

  // ---------------------------------------------------------------------------
  // Import and export
  // ---------------------------------------------------------------------------

  /// Imports a SurrealQL document into the current namespace and database.
  Future<void> import(String surql) async {
    final response = await _http.post(
      _httpBase().replace(path: '/import'),
      headers: _httpHeaders(contentType: 'text/plain'),
      body: surql,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpConnectionError(
        'Import failed with status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  /// Exports the current namespace and database as a SurrealQL document.
  Future<String> export() async {
    final response = await _http.get(
      _httpBase().replace(path: '/export'),
      headers: _httpHeaders(accept: 'text/plain'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpConnectionError(
        'Export failed with status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return utf8.decode(response.bodyBytes);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  http.Client get _http {
    final client = _httpClient;
    if (client == null) throw const ConnectionUnavailableError();
    return client;
  }

  /// Sends an RPC call. A result of NONE, which methods that return nothing
  /// give, comes back as null.
  Future<Object?> _rpc(String method, [List<Object?> params = const []]) async {
    final engine = _engine;
    if (engine == null) throw const ConnectionUnavailableError();
    final result = await engine.rpc(method, params);
    return result is SurrealNone ? null : result;
  }

  SurrealValue _thing(Object resource) {
    if (resource is SurrealValue) return resource;
    if (resource is String) {
      return resource.contains(':')
          ? StringRecordId(resource)
          : Table(resource);
    }
    throw ArgumentError(
        'A resource must be a String, Table, RecordId, StringRecordId, or '
        'RecordIdRange, got ${resource.runtimeType}');
  }

  /// Coerces a live query id result into a [Uuid]. The CBOR codec returns a
  /// [Uuid] directly, while the JSON codec returns the canonical string form.
  Uuid _asUuid(Object? result) {
    if (result is Uuid) return result;
    if (result is String) return Uuid(result);
    throw ResponseError('Expected a live query id, got $result');
  }

  Tokens _tokensFrom(Object? result) => Tokens(
        access: SessionState.accessTokenOf(result) ?? '',
        refresh: SessionState.refreshTokenOf(result),
      );

  Uri _httpBase() {
    final uri = _url;
    if (uri == null) throw const ConnectionUnavailableError();
    final scheme = switch (uri.scheme) {
      'ws' => 'http',
      'wss' => 'https',
      final other => other,
    };
    return Uri(
        scheme: scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
  }

  Map<String, String> _httpHeaders({String? contentType, String? accept}) => {
        if (contentType != null) 'Content-Type': contentType,
        if (accept != null) 'Accept': accept,
        if (_session.token != null) 'Authorization': 'Bearer ${_session.token}',
        if (_session.namespace != null) 'Surreal-NS': _session.namespace!,
        if (_session.database != null) 'Surreal-DB': _session.database!,
      };
}

/// Whether [version], as returned by the `version` RPC (for example
/// `surrealdb-3.3.4` or `3.4.0-nightly+20261014`), is within the range this
/// client supports.
bool isSupportedServerVersion(String version) {
  final parsed = _parseVersion(version);
  if (parsed == null) return false;
  return _compareVersions(parsed, _parseVersion(minimumServerVersion)!) >= 0 &&
      _compareVersions(parsed, _parseVersion(maximumServerVersion)!) < 0;
}

final RegExp _versionPattern = RegExp(r'(\d+)\.(\d+)\.(\d+)');

List<int>? _parseVersion(String version) {
  final match = _versionPattern.firstMatch(version);
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}

int _compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}
