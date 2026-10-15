part of 'surreal.dart';

/// The queries and record operations shared by the client, its sessions and
/// their transactions. Each runs in the session or transaction it is called
/// on.
mixin SurrealQueryable {
  /// Sends an RPC call in this session or transaction. A result of NONE,
  /// which methods that return nothing give, comes back as null.
  Future<Object?> _call(String method, [List<Object?> params = const []]);

  /// Sends an RPC call whose reply is streamed, in this session or
  /// transaction.
  Stream<Object?> _callStream(String method, List<Object?> params);

  Surreal get _client;

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
    final result = await _call('query', [query, bindings ?? const {}]);
    return (result as List).cast<Map<String, dynamic>>();
  }

  /// Runs a SurrealQL query and streams its results as they are produced,
  /// rather than waiting for the whole result. See [QueryFrame] for what
  /// arrives and in which order.
  ///
  /// Over WebSocket, against SurrealDB 3.3 or later, rows arrive in batches
  /// while the query runs, and cancelling the subscription cancels the query
  /// on the server. Otherwise the query runs as with [query] and its results
  /// are given as frames once it completes, so the same code works
  /// everywhere.
  ///
  /// A failed statement does not end the stream: its [QueryStatementDone]
  /// carries the error. The stream fails only when the query as a whole
  /// fails, for example on a parse error.
  ///
  /// ```dart
  /// await for (final frame in db.queryStream('SELECT * FROM event')) {
  ///   if (frame is QueryRows) frame.values.forEach(handle);
  /// }
  /// ```
  Stream<QueryFrame> queryStream(String query,
      {Map<String, Object?>? bindings}) async* {
    final params = [query, bindings ?? const <String, Object?>{}];
    if (_client._canStream) {
      var started = false;
      try {
        await for (final raw in _callStream('query_stream', params)) {
          started = true;
          final frame = _frameFrom(raw);
          if (frame != null) yield frame;
        }
        return;
      } on ServerError catch (error) {
        // A server that does not know query_stream says so before sending
        // anything. Remember that, and run the query buffered instead.
        if (started || error.code != -32601) rethrow;
        _client._streamingUnsupported = true;
      }
    }
    final statements = await queryRaw(query, bindings: bindings);
    for (final (index, statement) in statements.indexed) {
      final time = statement['time']?.toString();
      final type = statement['type'];
      if (statement['status'] != 'OK') {
        yield QueryStatementDone(index,
            time: time,
            type: type is String ? type : null,
            error: ServerError.fromStatement(statement, index: index));
        continue;
      }
      final result = statement['result'];
      if (result is List) {
        if (result.isNotEmpty) yield QueryRows(index, result);
      } else {
        yield QueryValue(index, result);
      }
      yield QueryStatementDone(index,
          single: result is! List,
          time: time,
          type: type is String ? type : null);
    }
  }

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  /// Selects records. A record id returns a single record or null, a table or
  /// range returns a list.
  Future<dynamic> select(Object resource) =>
      _call('select', [_thing(resource)]);

  /// Creates a record. [data] is the record content.
  Future<dynamic> create(Object resource, [Object? data]) =>
      _call('create', [_thing(resource), if (data != null) data]);

  /// Inserts one record or a list of records into [table].
  Future<dynamic> insert(Object table, Object data) =>
      _call('insert', [_thing(table), data]);

  /// Inserts one or more graph edges into [table].
  Future<dynamic> insertRelation(Object table, Object data) =>
      _call('insert_relation', [_thing(table), data]);

  /// Replaces the content of the matching records with [data].
  Future<dynamic> update(Object resource, Object data) =>
      _call('update', [_thing(resource), data]);

  /// Creates the record if it is missing, otherwise replaces its content.
  Future<dynamic> upsert(Object resource, Object data) =>
      _call('upsert', [_thing(resource), data]);

  /// Merges [data] into the matching records, leaving other fields untouched.
  Future<dynamic> merge(Object resource, Object data) =>
      _call('merge', [_thing(resource), data]);

  /// Applies a list of JSON Patch operations to the matching records. When
  /// [diff] is true the server returns the applied patches instead of the
  /// records.
  Future<dynamic> patch(Object resource, List<Patch> patches,
          {bool diff = false}) =>
      _call('patch', [
        _thing(resource),
        [for (final patch in patches) patch.toJson()],
        diff,
      ]);

  /// Deletes the matching records and returns them.
  Future<dynamic> delete(Object resource) =>
      _call('delete', [_thing(resource)]);

  /// Creates a graph edge from [from] to [to] through the [edge] table or
  /// record, optionally carrying [data].
  Future<dynamic> relate(Object from, Object edge, Object to, [Object? data]) =>
      _call('relate', [
        _thing(from),
        _thing(edge),
        _thing(to),
        if (data != null) data,
      ]);

  /// Runs a built in or user defined function and returns its result.
  Future<dynamic> run(String name, {String? version, List<Object?>? args}) =>
      _call('run', [name, version, args ?? const []]);
}

SurrealValue _thing(Object resource) {
  if (resource is SurrealValue) return resource;
  if (resource is String) {
    return resource.contains(':') ? StringRecordId(resource) : Table(resource);
  }
  throw ArgumentError(
      'A resource must be a String, Table, RecordId, StringRecordId, or '
      'RecordIdRange, got ${resource.runtimeType}');
}

/// Coerces a live query or transaction id result into a [Uuid]. The CBOR
/// codec returns a [Uuid] directly, while the JSON codec returns the
/// canonical string form.
Uuid _asUuid(Object? result) {
  if (result is Uuid) return result;
  if (result is String) return Uuid(result);
  throw ResponseError('Expected a UUID, got $result');
}

Tokens _tokensFrom(Object? result) => Tokens(
      access: SessionState.accessTokenOf(result) ?? '',
      refresh: SessionState.refreshTokenOf(result),
    );

/// Turns one `query_stream` reply into a [QueryFrame], or null for the frames
/// that only frame the stream.
QueryFrame? _frameFrom(Object? raw) {
  if (raw is! Map) throw ResponseError('Unexpected stream frame: $raw');
  final index = raw['index'] is int ? raw['index'] as int : 0;
  switch (raw['stream']) {
    case 'begin':
      final version = raw['version'];
      if (version is int && version > 1) {
        throw ResponseError(
            'The server streams with protocol version $version, which this '
            'client does not understand');
      }
      return null;
    case 'rows':
      return QueryRows(index, (raw['values'] as List?) ?? const []);
    case 'value':
      return QueryValue(index, raw['value']);
    case 'finished':
      final error = raw['error'];
      final type = raw['type'];
      return QueryStatementDone(
        index,
        single: raw['single'] == true,
        time: raw['time']?.toString(),
        type: type is String ? type : null,
        error: error is Map
            ? ServerError.fromRpc(error, statementIndex: index)
            : null,
      );
    case 'end':
      final error = raw['error'];
      if (error is Map) throw ServerError.fromRpc(error);
      return null;
    default:
      return null;
  }
}
