import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'engine/engine.dart';
import 'engine/http_engine.dart';
import 'engine/websocket_engine.dart';
import 'errors.dart';
import 'live_query.dart';
import 'protocol/codecs.dart';
import 'types/auth.dart';
import 'types/connection.dart';
import 'types/live.dart';
import 'types/patch.dart';
import 'value/value.dart';

/// The minimum SurrealDB server version this client targets.
const String _minimumVersion = '1.4.2';

class _LiveRegistration {
  _LiveRegistration(this.query, this.resource, this.diff);

  final LiveQuery query;
  final Object resource;
  final bool diff;
}

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
  final http.Client _httpClient = http.Client();

  String? _namespace;
  String? _database;
  String? _accessToken;
  String? _version;

  final Map<String, _LiveRegistration> _liveByUuid = {};
  StreamSubscription<LiveMessage>? _liveSubscription;

  /// The namespace currently selected, if any.
  String? get namespace => _namespace;

  /// The database currently selected, if any.
  String? get database => _database;

  /// The access token in use, if the session is authenticated.
  String? get accessToken => _accessToken;

  /// The server version, available after [connect] with a version check or a
  /// call to [version].
  String? get serverVersion => _version;

  /// The current connection status.
  ConnectionStatus get status =>
      _engine?.status ?? ConnectionStatus.disconnected;

  /// Whether there is an open connection.
  bool get isConnected => status == ConnectionStatus.connected;

  /// Emits whenever the connection status changes.
  Stream<ConnectionStatus> get statusChanges =>
      _engine?.statusChanges ?? const Stream.empty();

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Connects to the server at [url]. The scheme selects the engine: `ws` and
  /// `wss` use the WebSocket engine, `http` and `https` use the HTTP engine.
  Future<void> connect(String url,
      {ConnectOptions options = const ConnectOptions()}) async {
    final uri = Uri.parse(url);
    final engine = _engineFor(uri, options);
    _engine = engine;
    _url = uri;
    engine.onReconnect = _restartLiveQueries;
    _liveSubscription = engine.liveNotifications.listen(_routeLive);

    await engine.open(uri, timeout: options.timeout);

    if (options.namespace != null || options.database != null) {
      await use(namespace: options.namespace, database: options.database);
    }
    if (options.authentication != null) {
      await signin(options.authentication!);
    } else if (options.token != null) {
      await authenticate(options.token!);
    }
    if (options.versionCheck) {
      await _checkVersion();
    }
  }

  Engine _engineFor(Uri uri, ConnectOptions options) {
    final codec = options.codec ?? codecForFormat(options.format);
    switch (uri.scheme) {
      case 'ws':
      case 'wss':
        return WebSocketEngine(codec, reconnect: options.reconnect);
      case 'http':
      case 'https':
        return HttpEngine(codec, client: _httpClient);
      default:
        throw UnsupportedEngineError(uri.scheme);
    }
  }

  /// Closes the connection and releases resources. Active live queries are
  /// closed.
  Future<void> close() async {
    await _liveSubscription?.cancel();
    _liveSubscription = null;
    for (final reg in _liveByUuid.values) {
      await reg.query.dispose();
    }
    _liveByUuid.clear();
    await _engine?.close();
    _httpClient.close();
    _engine = null;
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
    final response = await _httpClient.get(base.replace(path: '/health'));
    if (response.statusCode != 200) {
      throw HttpConnectionError(
        'Health check failed with status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> _checkVersion() async {
    final version = await this.version();
    final parts = version.split('.');
    if (parts.isEmpty) return;
    final major = int.tryParse(parts.first.replaceAll(RegExp(r'[^0-9]'), ''));
    if (major != null && major < 1) {
      throw UnsupportedVersionError(version, _minimumVersion);
    }
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  /// Selects the [namespace] and [database] for subsequent operations. A value
  /// left null keeps the currently selected one.
  Future<void> use({String? namespace, String? database}) async {
    final ns = namespace ?? _namespace;
    final db = database ?? _database;
    await _rpc('use', [ns, db]);
    _namespace = ns;
    _database = db;
  }

  /// Signs up a new record access user and returns the issued tokens.
  Future<Tokens> signup(AccessRecordAuth auth) async {
    final result = await _rpc('signup', [auth.toJson()]);
    final tokens = _tokensFrom(result);
    _accessToken = tokens.access;
    return tokens;
  }

  /// Signs in with the given credentials and returns the issued tokens.
  Future<Tokens> signin(AnyAuth auth) async {
    final result = await _rpc('signin', [auth.toJson()]);
    final tokens = _tokensFrom(result);
    _accessToken = tokens.access;
    return tokens;
  }

  /// Authenticates the current session with an existing token.
  Future<void> authenticate(String token) async {
    await _rpc('authenticate', [token]);
    _accessToken = token;
  }

  /// Invalidates the current session, signing out.
  Future<void> invalidate() async {
    await _rpc('invalidate');
    _accessToken = null;
  }

  /// Returns the record associated with the current authentication, or null.
  Future<Map<String, dynamic>?> info() async {
    final result = await _rpc('info');
    return result as Map<String, dynamic>?;
  }

  /// Defines a connection wide parameter that can be used in queries as `$key`.
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
  /// Throws a [QueryStatementError] if any statement fails.
  ///
  /// Bind parameters by referencing them as `$name` in [query] and passing the
  /// values in [bindings].
  Future<List<Object?>> query(String query,
      {Map<String, Object?>? bindings}) async {
    final statements = await queryRaw(query, bindings: bindings);
    final results = <Object?>[];
    for (final statement in statements) {
      if (statement['status'] != 'OK') {
        throw QueryStatementError(
            statement['result']?.toString() ?? 'Query statement failed');
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

  Future<void> _restartLiveQueries() async {
    final registrations = List.of(_liveByUuid.values);
    _liveByUuid.clear();
    for (final registration in registrations) {
      final uuid = _asUuid(await _rpc('live', [
        _thing(registration.resource),
        registration.diff,
      ]));
      registration.query.rebind(uuid);
      _liveByUuid[uuid.toString()] = registration;
    }
  }

  // ---------------------------------------------------------------------------
  // Import and export
  // ---------------------------------------------------------------------------

  /// Imports a SurrealQL document into the current namespace and database.
  Future<void> import(String surql) async {
    final response = await _httpClient.post(
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
    final response = await _httpClient.get(
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

  Future<Object?> _rpc(String method, [List<Object?> params = const []]) {
    final engine = _engine;
    if (engine == null) throw const ConnectionUnavailableError();
    return engine.rpc(method, params);
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

  Tokens _tokensFrom(Object? result) {
    if (result is String) return Tokens(access: result);
    if (result is Map) {
      return Tokens(
        access: result['token']?.toString() ?? '',
        refresh: result['refresh']?.toString(),
      );
    }
    return const Tokens(access: '');
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
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
        if (_namespace != null) 'Surreal-NS': _namespace!,
        if (_database != null) 'Surreal-DB': _database!,
      };
}
