/// Base class for every error raised by the SurrealDB driver.
class SurrealError implements Exception {
  const SurrealError(this.message, {this.cause});

  /// A human readable description of what went wrong.
  final String message;

  /// The underlying error, when this error wraps another one.
  final Object? cause;

  @override
  String toString() {
    final base = '$runtimeType: $message';
    return cause == null ? base : '$base (cause: $cause)';
  }
}

/// Thrown when a connection URL uses a scheme that has no registered engine,
/// for example `tcp://`.
class UnsupportedEngineError extends SurrealError {
  const UnsupportedEngineError(this.scheme)
      : super('No engine is registered for the "$scheme" scheme');

  final String scheme;
}

/// Thrown when a method is called that needs an active connection but none is
/// available.
class ConnectionUnavailableError extends SurrealError {
  const ConnectionUnavailableError()
      : super('The client is not connected to a SurrealDB instance');
}

/// Thrown when a query needs a namespace and database but one or both have not
/// been selected with `use`.
class MissingNamespaceDatabaseError extends SurrealError {
  const MissingNamespaceDatabaseError(super.message);
}

/// Thrown when the server returns an error in response to an RPC call, or
/// when its response cannot be understood. Errors the server reports are
/// [ServerError]s.
class ResponseError extends SurrealError {
  const ResponseError(super.message, {this.code, super.cause});

  /// The JSON-RPC error code, when present.
  final int? code;
}

/// Thrown when a single statement inside a `query` batch fails. The other
/// statements in the same batch may have succeeded.
@Deprecated('Catch ServerError, or one of its kinds, instead. A failed '
    'statement is a ServerError with a statementIndex.')
typedef QueryStatementError = ServerError;

/// The category of an error reported by the server.
enum ErrorKind {
  /// The request or its parameters were invalid, including parse errors.
  validation('Validation'),

  /// A feature is not configured or not supported, such as live queries on
  /// a datastore without them.
  configuration('Configuration'),

  /// A query did not run to completion: not executed, timed out, cancelled or
  /// in a transaction that conflicted.
  query('Query'),

  /// A value could not be serialized or deserialized.
  serialization('Serialization'),

  /// The operation is not permitted, including every authentication failure.
  notAllowed('NotAllowed'),

  /// A method, session, table, record, namespace, database or transaction
  /// does not exist.
  notFound('NotFound'),

  /// A session, table, record, namespace or database already exists.
  alreadyExists('AlreadyExists'),

  /// The server's own connection state was wrong for the request.
  connection('Connection'),

  /// A `THROW` statement or a function raised the error.
  thrown('Thrown'),

  /// An unexpected error inside the server.
  internal('Internal'),

  /// The request's context, for example its deadline, ended it.
  context('Context');

  const ErrorKind(this.wireName);

  /// The name the server uses for this kind.
  final String wireName;

  /// The kind for a server kind name. An unknown name is [internal].
  static ErrorKind parse(String? name) {
    for (final kind in values) {
      if (kind.wireName == name) return kind;
    }
    return internal;
  }

  /// The kind implied by a JSON-RPC error code, for servers that do not send
  /// a kind.
  static ErrorKind fromCode(int? code) => switch (code) {
        -32700 || -32600 || -32603 => validation,
        -32601 => notFound,
        -32602 || -32002 => notAllowed,
        -32604 || -32605 || -32606 || -32607 => configuration,
        -32003 || -32004 || -32005 || -32009 => query,
        -32006 => thrown,
        -32007 || -32008 => serialization,
        _ => internal,
      };
}

/// The detail attached to a [ServerError]: a [kind] name, such as `Auth` or
/// `Table`, and either a nested [inner] detail or a map of [fields].
///
/// For example the server reports an expired token as a `NotAllowed` error
/// whose detail is `Auth`, with an inner detail of `TokenExpired`, and a
/// missing table as a `NotFound` error whose detail is `Table` with the field
/// `name`.
class ErrorDetail {
  const ErrorDetail(this.kind, {this.inner, this.fields = const {}});

  /// Reads the `{kind, details}` wire form. Returns null for anything else.
  static ErrorDetail? fromWire(Object? value) {
    if (value is! Map || value['kind'] is! String) return null;
    final details = value['details'];
    final inner = fromWire(details);
    return ErrorDetail(
      value['kind'] as String,
      inner: inner,
      fields: inner == null && details is Map
          ? {for (final e in details.entries) e.key.toString(): e.value}
          : const {},
    );
  }

  /// The name of this detail.
  final String kind;

  /// A more specific detail, when the server nests one.
  final ErrorDetail? inner;

  /// The values this detail carries, for example `name` or `id`.
  final Map<String, Object?> fields;

  /// Whether this detail, or any detail nested inside it, is [kind], in
  /// order. For example `has('Auth', 'TokenExpired')`.
  bool has(String kind, [String? innerKind]) =>
      this.kind == kind && (innerKind == null || inner?.kind == innerKind);

  @override
  String toString() => inner != null
      ? '$kind($inner)'
      : fields.isEmpty
          ? kind
          : '$kind$fields';
}

/// An error reported by the server, with its [kind], JSON-RPC [code] and
/// structured [details].
///
/// Each kind has its own subclass, so callers can catch, for example, a
/// [NotFoundError] or a [NotAllowedError]. A failed statement in a `query`
/// batch is thrown as a [ServerError] too, with [statementIndex] set and a
/// [code] of 0.
class ServerError extends ResponseError {
  ServerError(
    super.message, {
    required this.kind,
    this.rawKind,
    super.code,
    this.details,
    ServerError? cause,
    this.statementIndex,
  }) : super(cause: cause);

  /// Builds the subclass for [kind].
  factory ServerError.of(
    String message, {
    required ErrorKind kind,
    String? rawKind,
    int? code,
    ErrorDetail? details,
    ServerError? cause,
    int? statementIndex,
  }) {
    final make = switch (kind) {
      ErrorKind.validation => ValidationError.new,
      ErrorKind.configuration => ConfigurationError.new,
      ErrorKind.query => QueryError.new,
      ErrorKind.serialization => SerializationError.new,
      ErrorKind.notAllowed => NotAllowedError.new,
      ErrorKind.notFound => NotFoundError.new,
      ErrorKind.alreadyExists => AlreadyExistsError.new,
      ErrorKind.connection => ServerConnectionError.new,
      ErrorKind.thrown => ThrownError.new,
      ErrorKind.internal => InternalError.new,
      ErrorKind.context => ContextError.new,
    };
    return make(
      message,
      rawKind: rawKind,
      code: code,
      details: details,
      cause: cause,
      statementIndex: statementIndex,
    );
  }

  /// Reads an RPC `error` object: `{code, message, kind?, details?, cause?}`.
  factory ServerError.fromRpc(Map<dynamic, dynamic> error) {
    final code = error['code'] is int ? error['code'] as int : null;
    final rawKind = error['kind'] is String ? error['kind'] as String : null;
    final cause = error['cause'];
    return ServerError.of(
      error['message']?.toString() ?? 'RPC error',
      kind:
          rawKind != null ? ErrorKind.parse(rawKind) : ErrorKind.fromCode(code),
      rawKind: rawKind,
      code: code,
      details: ErrorDetail.fromWire(error['details']),
      cause: cause is Map ? ServerError.fromRpc(cause) : null,
    );
  }

  /// Reads a failed statement from a `query` result:
  /// `{status: "ERR", result: message, kind?, details?}`.
  factory ServerError.fromStatement(Map<dynamic, dynamic> statement,
      {int? index}) {
    final rawKind =
        statement['kind'] is String ? statement['kind'] as String : null;
    return ServerError.of(
      statement['result']?.toString() ?? 'Query statement failed',
      // Servers before 3.0 send no kind, so nothing says what went wrong.
      // Thrown is only for THROW statements.
      kind: rawKind != null ? ErrorKind.parse(rawKind) : ErrorKind.internal,
      rawKind: rawKind,
      code: 0,
      details: ErrorDetail.fromWire(statement['details']),
      statementIndex: index,
    );
  }

  /// The category of the error. An unrecognised kind is [ErrorKind.internal].
  final ErrorKind kind;

  /// The kind name exactly as the server sent it, when it sent one.
  final String? rawKind;

  /// The structured detail, when the server sent one.
  final ErrorDetail? details;

  /// For a failed statement in a `query` batch, its position in the batch.
  final int? statementIndex;

  /// The server error that caused this one, if any.
  @override
  ServerError? get cause => super.cause as ServerError?;

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message');
    if (details != null) buffer.write(' [$details]');
    if (statementIndex != null) buffer.write(' (statement $statementIndex)');
    if (cause != null) buffer.write(' (cause: $cause)');
    return buffer.toString();
  }
}

/// The request or its parameters were invalid.
class ValidationError extends ServerError {
  ValidationError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.validation);

  /// Whether the query could not be parsed.
  bool get isParseError => details?.kind == 'Parse';

  /// The name of the invalid parameter, when that is what failed.
  String? get parameterName => details?.kind == 'InvalidParameter'
      ? details!.fields['name'] as String?
      : null;
}

/// A feature is not configured or not supported by the server.
class ConfigurationError extends ServerError {
  ConfigurationError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.configuration);

  /// Whether the datastore does not support live queries.
  bool get isLiveQueryNotSupported => details?.kind == 'LiveQueryNotSupported';
}

/// A query did not run to completion.
class QueryError extends ServerError {
  QueryError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.query);

  /// Whether the query was not executed, for example because an earlier
  /// statement in its transaction failed.
  bool get isNotExecuted => details?.kind == 'NotExecuted';

  /// Whether the query ran past its timeout.
  bool get isTimedOut => details?.kind == 'TimedOut';

  /// Whether the query was cancelled.
  bool get isCancelled => details?.kind == 'Cancelled';

  /// Whether the transaction conflicted with another one and can be retried.
  bool get isTransactionConflict => details?.kind == 'TransactionConflict';

  /// The timeout that was exceeded, when [isTimedOut].
  Object? get timeout => isTimedOut ? details!.fields['duration'] : null;
}

/// A value could not be serialized or deserialized.
class SerializationError extends ServerError {
  SerializationError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.serialization);

  /// Whether the failure was while deserializing.
  bool get isDeserialization => details?.kind == 'Deserialization';
}

/// The operation is not permitted. Every authentication failure has this
/// kind.
class NotAllowedError extends ServerError {
  NotAllowedError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.notAllowed);

  /// Whether the access token has expired.
  bool get isTokenExpired => details?.has('Auth', 'TokenExpired') ?? false;

  /// Whether the session has expired.
  bool get isSessionExpired => details?.has('Auth', 'SessionExpired') ?? false;

  /// Whether the credentials or token were rejected.
  bool get isInvalidAuth => details?.has('Auth', 'InvalidAuth') ?? false;

  /// Whether the failure is about authentication at all.
  bool get isAuthError => details?.kind == 'Auth';

  /// Whether scripting is disabled on the server.
  bool get isScriptingBlocked => details?.kind == 'Scripting';

  /// The RPC method that is not allowed, when that is what failed.
  String? get methodName =>
      details?.kind == 'Method' ? details!.fields['name'] as String? : null;

  /// The function that is not allowed, when that is what failed.
  String? get functionName =>
      details?.kind == 'Function' ? details!.fields['name'] as String? : null;
}

/// Something the request refers to does not exist.
class NotFoundError extends ServerError {
  NotFoundError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.notFound);

  Object? _field(String kind, String field) =>
      details?.kind == kind ? details!.fields[field] : null;

  /// The missing RPC method.
  String? get methodName => _field('Method', 'name') as String?;

  /// The missing table.
  String? get tableName => _field('Table', 'name') as String?;

  /// The missing record.
  Object? get recordId => _field('Record', 'id');

  /// The missing namespace.
  String? get namespaceName => _field('Namespace', 'name') as String?;

  /// The missing database.
  String? get databaseName => _field('Database', 'name') as String?;

  /// The missing session.
  Object? get sessionId => _field('Session', 'id');

  /// Whether the transaction does not exist.
  bool get isTransaction => details?.kind == 'Transaction';
}

/// Something the request would create already exists.
class AlreadyExistsError extends ServerError {
  AlreadyExistsError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.alreadyExists);

  Object? _field(String kind, String field) =>
      details?.kind == kind ? details!.fields[field] : null;

  /// The record that already exists.
  Object? get recordId => _field('Record', 'id');

  /// The table that already exists.
  String? get tableName => _field('Table', 'name') as String?;

  /// The session that already exists.
  Object? get sessionId => _field('Session', 'id');

  /// The namespace that already exists.
  String? get namespaceName => _field('Namespace', 'name') as String?;

  /// The database that already exists.
  String? get databaseName => _field('Database', 'name') as String?;
}

/// The server's connection state was wrong for the request. This is about
/// the server side of the connection; a dropped connection is reported as a
/// [ConnectionUnavailableError] instead.
class ServerConnectionError extends ServerError {
  ServerConnectionError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.connection);
}

/// A `THROW` statement or a function raised the error.
class ThrownError extends ServerError {
  ThrownError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.thrown);
}

/// An unexpected error inside the server, or a kind this client does not
/// recognise.
class InternalError extends ServerError {
  InternalError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.internal);
}

/// The request's context, for example its deadline, ended it.
class ContextError extends ServerError {
  ContextError(super.message,
      {super.rawKind,
      super.code,
      super.details,
      super.cause,
      super.statementIndex})
      : super(kind: ErrorKind.context);
}

/// Thrown when authentication fails or when an operation requires an
/// authenticated session.
class AuthenticationError extends SurrealError {
  const AuthenticationError(super.message, {super.cause});
}

/// Thrown when an engine does not support a requested feature, for example
/// live queries over the HTTP engine.
class UnsupportedFeatureError extends SurrealError {
  const UnsupportedFeatureError(this.feature)
      : super('The current engine does not support "$feature"');

  final String feature;
}

/// Thrown when the server version is outside the range this client supports.
class UnsupportedVersionError extends SurrealError {
  const UnsupportedVersionError(this.version, this.minimum, this.maximum)
      : super('Unsupported server version $version, this client supports '
            '$minimum up to but not including $maximum');

  /// The version the server reported.
  final String version;

  /// The lowest supported version.
  final String minimum;

  /// The first version that is no longer supported.
  final String maximum;
}

/// Thrown when the HTTP engine receives a non success status code.
class HttpConnectionError extends SurrealError {
  const HttpConnectionError(super.message, {required this.statusCode});

  final int statusCode;
}

/// Thrown when the server does not reply to a request within the configured
/// request timeout. The request may still run on the server.
class RequestTimeoutError extends SurrealError {
  const RequestTimeoutError(this.method, this.timeout)
      : super('The "$method" request timed out after $timeout');

  /// The RPC method that timed out.
  final String method;

  /// The timeout that was exceeded.
  final Duration timeout;
}

/// Delivered on the stream of a live query attached with `liveOf` when the
/// connection was re-established. The client cannot restart such a query, so
/// its stream closes after this error.
class LiveQueryLostError extends SurrealError {
  LiveQueryLostError(this.id)
      : super('The live query $id was lost when the connection was '
            're-established');

  /// The id of the lost live query.
  final Object id;
}
