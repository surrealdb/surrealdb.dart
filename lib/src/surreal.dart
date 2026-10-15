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

part 'queryable.dart';
part 'renewal.dart';
part 'session.dart';
part 'transaction.dart';

/// The lowest SurrealDB server version this client accepts.
const String minimumServerVersion = '1.4.2';

/// The first SurrealDB server version this client no longer accepts.
const String maximumServerVersion = '5.0.0';

class _LiveRegistration {
  _LiveRegistration(this.query, this.session, this.resource, this.diff);

  final LiveQuery query;

  /// The attached session the query runs in, or null for the default one.
  final Uuid? session;

  /// What the live query selects from, or null for a query attached with
  /// `liveOf`, which the client cannot restart.
  final Object? resource;
  final bool diff;
}

/// A client for a single SurrealDB connection.
///
/// Create an instance, [connect] to a server, select a namespace and database
/// with [use], authenticate, then run queries and CRUD operations. Live queries
/// are returned as [LiveQuery] handles whose change notifications arrive on a
/// [Stream].
///
/// The client is the connection's default session. Over WebSocket, more
/// sessions can share the connection: see [newSession] and [forkSession].
///
/// ```dart
/// final db = Surreal();
/// await db.connect('ws://127.0.0.1:8000/rpc');
/// await db.use(namespace: 'test', database: 'test');
/// await db.signin(const RootAuth(username: 'root', password: 'root'));
/// final created = await db.create('person', {'name': 'Tobie'});
/// ```
class Surreal with SurrealQueryable, SurrealSessionMethods {
  Engine? _engine;
  Uri? _url;
  http.Client? _httpClient;
  StreamSubscription<ConnectionStatus>? _statusSubscription;
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus? _publishedStatus;

  late final SessionState _session = SessionState()
    ..onTokensChanged = _onTokensChanged;
  String? _version;
  var _versionCheck = true;

  /// Whether the codec is the built-in one for the format, rather than one
  /// the caller supplied.
  var _ownCodec = true;

  // Token renewal.
  var _renewTokens = true;
  var _tokenExpiryMargin = const Duration(seconds: 60);
  @override
  late final _TokenRenewal _renewal =
      _TokenRenewal(this, _session, null, onError: (error, stackTrace) {
    if (!_authController.isClosed) _authController.addError(error, stackTrace);
  });
  final _authController = StreamController<Tokens?>.broadcast();

  final Map<String, _LiveRegistration> _liveByUuid = {};
  StreamSubscription<LiveMessage>? _liveSubscription;

  /// The sessions attached to the connection, by id.
  final Map<Uuid, SurrealSession> _attached = {};

  @override
  Surreal get _client => this;

  @override
  Uuid? get _sessionId => null;

  @override
  SessionState get _state => _session;

  /// Emits the new [tokens] whenever they change: after signing in, a
  /// refresh, an automatic renewal or a reconnect that had to refresh. Emits
  /// null when the session loses its authentication. A failed automatic
  /// renewal is delivered as an error.
  Stream<Tokens?> get authChanges => _authController.stream;

  /// The server version, available after [connect] with a version check or a
  /// call to [version].
  String? get serverVersion => _version;

  /// The current connection status.
  ConnectionStatus get status {
    final status = _engine?.status ?? ConnectionStatus.disconnected;
    return _verifying && status == ConnectionStatus.connected
        ? ConnectionStatus.connecting
        : status;
  }

  /// Whether [connect] is still checking the server, so the connection is
  /// not yet reported as connected.
  var _verifying = false;

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
    _versionCheck = options.versionCheck;
    engine.onVerify = _verifyServer;
    engine.onReconnect = _restartLiveQueries;
    engine.onAuthenticationLost = _signInAgain;
    _renewTokens = options.renewTokens;
    _tokenExpiryMargin = options.tokenExpiryMargin;
    _liveSubscription = engine.liveNotifications.listen(_routeLive);
    _statusSubscription = engine.statusChanges.listen(_publishStatus);

    _ownCodec = options.codec == null;
    // Until the version is known, sets go as arrays, which every server takes.
    _adaptCodec();
    // The server is checked before anyone is told the connection is open.
    _verifying = options.versionCheck;
    try {
      await engine.open(uri, timeout: options.timeout);
      if (options.versionCheck) await _checkVersion();
    } catch (_) {
      _verifying = false;
      await close();
      rethrow;
    }
    _verifying = false;
    _publishStatus(engine.status);
    if (options.namespace != null || options.database != null) {
      await use(
        namespace: options.namespace ?? _unchanged,
        database: options.database ?? _unchanged,
      );
    }
    final credentials = options.authentication;
    if (credentials != null) {
      // Without a refresh token, renewal signs in again with these.
      _renewal.credentials = credentials;
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
    for (final session in _attached.values) {
      session._closed = true;
      session._renewal.stop();
    }
    _attached.clear();
    final engine = _engine;
    _engine = null;
    try {
      await engine?.close();
    } finally {
      await _statusSubscription?.cancel();
      _statusSubscription = null;
      // The engine's own event may not have been forwarded before the
      // subscription was cancelled; publishing only changes sends it once.
      if (engine != null) _publishStatus(ConnectionStatus.disconnected);
      _httpClient?.close();
      _httpClient = null;
      _session.clear(cleared: false);
      _renewal.cancel();
      _version = null;
    }
  }

  void _publishStatus(ConnectionStatus status) {
    if (_verifying && status == ConnectionStatus.connected) return;
    if (status == _publishedStatus) return;
    _publishedStatus = status;
    _statusController.add(status);
  }

  /// Returns the server version string, for example `2.1.0`.
  Future<String> version() async {
    final version = _versionOf(await _rpc('version', const []));
    _version = version;
    _adaptCodec();
    return version ?? '';
  }

  /// Encodes sets as SurrealDB sets only for a server known to be 3.0 or
  /// later. Older servers have no set type and reject its CBOR tag, so sets
  /// go to them, and to a server whose version is not known, as arrays. A
  /// codec given in [ConnectOptions.codec] is left as it is.
  void _adaptCodec() {
    final engine = _engine;
    if (engine == null || !_ownCodec) return;
    final codec = engine.codec;
    if (codec is! CborCodec) return;
    final major = _parseVersion(_version ?? '')?.first;
    final arrays = major == null || major < 3;
    if (codec.setsAsArrays != arrays) {
      engine.codec = CborCodec(setsAsArrays: arrays);
    }
  }

  static String? _versionOf(Object? result) =>
      result is Map ? result['version']?.toString() : result?.toString();

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

  /// Runs when the WebSocket engine reconnects, before the session is
  /// restored. The server behind the URL may have changed, so its version is
  /// checked again. An unsupported server closes the client; any other
  /// failure fails the attempt, which the engine tries again.
  Future<void> _verifyServer(
      Future<Object?> Function(String method, List<Object?> params)
          call) async {
    if (!_versionCheck) {
      // The server may have changed, and its version is not checked, so
      // forget the old one and send sets as arrays again.
      _version = null;
      _adaptCodec();
      return;
    }
    final version = _versionOf(await call('version', const [])) ?? '';
    _version = version;
    // The session about to be replayed may hold sets.
    _adaptCodec();
    if (isSupportedServerVersion(version)) return;
    final error = UnsupportedVersionError(
        version, minimumServerVersion, maximumServerVersion);
    for (final registration in List.of(_liveByUuid.values)) {
      registration.query.emitError(error, StackTrace.current);
    }
    await close();
    throw error;
  }

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  /// Whether a `use` call can carry NONE to keep a value. A JSON WebSocket
  /// cannot; over HTTP the client applies `use` itself.
  bool get _canSendNone {
    final engine = _engine;
    return engine is! WebSocketEngine || engine.codec is CborCodec;
  }

  /// Attaches a new, empty session to the connection: no namespace,
  /// database, variables or authentication. See [SurrealSession].
  Future<SurrealSession> newSession() => _attachSession();

  /// The ids of the sessions attached to the connection, not counting the
  /// default session. Includes sessions attached by other clients of the same
  /// connection, if any.
  Future<List<Uuid>> sessions() async {
    _requireSessions('sessions');
    final result = await _rpc('sessions', const []);
    return [for (final id in result as List) _asUuid(id)];
  }

  Future<SurrealSession> _attachSession(
      {SessionState? copyOf, AnyAuth? credentials}) async {
    final engine = _requireSessions('sessions');
    final id = Uuid.v4();
    final state = SessionState();
    await _rpc('attach', const [], session: id);
    engine.trackSession(id, state);
    final session = SurrealSession._(this, id, state);
    state.onTokensChanged = session._renewal.reschedule;
    session._renewal.credentials = credentials;
    _attached[id] = session;
    if (copyOf != null) {
      try {
        if (copyOf.namespace != null || copyOf.database != null) {
          await _rpc('use', [copyOf.namespace, copyOf.database], session: id);
        }
        for (final MapEntry(:key, :value) in copyOf.variables.entries) {
          await _rpc('let', [key, value], session: id);
        }
        // The access token is shared, but not the refresh token: it can be
        // used only once, so two sessions renewing with it would fail.
        final token = copyOf.token;
        if (token != null) {
          await _rpc('authenticate', [token], session: id);
        }
      } catch (_) {
        await session.close();
        rethrow;
      }
    }
    return session;
  }

  /// Runs when a reconnect finds a session's tokens rejected. With token
  /// renewal on, signs the session in again with its credentials, if it has
  /// any; otherwise it carries on without authentication.
  Future<void> _signInAgain(
      Uuid? session,
      Object error,
      Future<Object?> Function(String method, List<Object?> params)
          call) async {
    final renewal = session == null ? _renewal : _attached[session]?._renewal;
    final credentials = renewal?.credentials;
    if (!_renewTokens || renewal == null || credentials == null) return;
    try {
      await call('signin', [credentials.toJson()]);
    } on ResponseError catch (error) {
      // Credentials that no longer work stay rejected; anything else fails
      // the attempt, which is tried again.
      if (!rejectsAuthentication(error)) rethrow;
      renewal.credentials = null;
    }
  }

  Engine _requireSessions(String feature) {
    final engine = _engine;
    if (engine == null) throw const ConnectionUnavailableError();
    if (!engine.supportsSessions) throw UnsupportedFeatureError(feature);
    return engine;
  }

  /// Reschedules renewal and tells listeners whenever the tokens change.
  void _onTokensChanged() {
    if (!_authController.isClosed) _authController.add(tokens);
    _renewal.reschedule();
  }

  // ---------------------------------------------------------------------------
  // Live queries
  // ---------------------------------------------------------------------------

  LiveQuery _registerLive(Uuid id, Uuid? session, Object? resource, bool diff) {
    final query = LiveQuery(id, _killLive);
    _liveByUuid[id.toString()] =
        _LiveRegistration(query, session, resource, diff);
    return query;
  }

  Future<void> _killLive(LiveQuery query) async {
    final registration = _liveByUuid[query.id.toString()];
    // Sent in the session the query runs in, and forgotten only once the
    // server has stopped it.
    await _rpc('kill', [query.id], session: registration?.session);
    _liveByUuid.remove(query.id.toString());
    await query.dispose();
  }

  /// Closes the streams of every live query of the given session, which the
  /// server has already stopped.
  Future<void> _disposeLiveQueries(Uuid? session) async {
    final registrations = [
      for (final entry in _liveByUuid.entries.toList())
        if (entry.value.session == session) entry,
    ];
    for (final entry in registrations) {
      _liveByUuid.remove(entry.key);
      // Not awaited: a paused listener would hold up the rest.
      unawaited(entry.value.query.dispose());
    }
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
        // Not awaited: a paused listener would hold up every other restart.
        unawaited(registration.query.dispose());
        continue;
      }
      final Uuid uuid;
      try {
        uuid = _asUuid(await _rpc(
          'live',
          [_thing(resource), registration.diff],
          session: registration.session,
        ));
      } catch (error, stackTrace) {
        registration.query.emitError(error, stackTrace);
        continue;
      }
      if (_liveByUuid.remove(oldId) == null) {
        // Killed while the restart was in flight, so stop the new query too.
        unawaited(_rpc('kill', [uuid], session: registration.session)
            .then((_) {}, onError: (_) {}));
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
  /// give, comes back as null, except from `run`, where it is the
  /// function's own result.
  Future<Object?> _rpc(String method, List<Object?> params,
      {Uuid? session, Uuid? txn}) async {
    final engine = _engine;
    if (engine == null) throw const ConnectionUnavailableError();
    final result = await engine.rpc(method, params, session: session, txn: txn);
    return result is SurrealNone && method != 'run' ? null : result;
  }

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
