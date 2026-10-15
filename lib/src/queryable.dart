part of 'surreal.dart';

/// The queries and record operations shared by the client, its sessions and
/// their transactions. Each runs in the session or transaction it is called
/// on.
mixin SurrealQueryable {
  /// Sends an RPC call in this session or transaction. A result of NONE,
  /// which methods that return nothing give, comes back as null.
  Future<Object?> _call(String method, [List<Object?> params = const []]);

  // ---------------------------------------------------------------------------
  // Query
  // ---------------------------------------------------------------------------

  /// Runs a SurrealQL query and returns the result of each statement in order.
  /// If any statement fails, throws the [ServerError] for the first failure,
  /// with its kind, details and [ServerError.statementIndex]. In a failed
  /// transaction the statements that were only not executed are passed over
  /// for the one that made it fail, such as a transaction conflict.
  ///
  /// Bind parameters by referencing them as `$name` in [query] and passing the
  /// values in [bindings].
  Future<List<Object?>> query(String query,
      {Map<String, Object?>? bindings}) async {
    final statements = await queryRaw(query, bindings: bindings);
    final results = <Object?>[];
    ServerError? failure;
    for (final (index, statement) in statements.indexed) {
      if (statement['status'] != 'OK') {
        final error = ServerError.fromStatement(statement, index: index);
        if (error is! QueryError || !error.isNotExecuted) throw error;
        failure ??= error;
      }
      results.add(statement['result']);
    }
    if (failure != null) throw failure;
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

  /// Runs a built in or user defined function and returns its result. A
  /// function that returns NONE gives [none], not null.
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
