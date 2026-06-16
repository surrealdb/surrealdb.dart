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

/// Thrown when the server returns an error in response to an RPC call.
class ResponseError extends SurrealError {
  const ResponseError(super.message, {this.code});

  /// The JSON-RPC error code, when present.
  final int? code;
}

/// Thrown when a single statement inside a `query` batch fails. The other
/// statements in the same batch may have succeeded.
class QueryStatementError extends SurrealError {
  const QueryStatementError(super.message);
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
  const UnsupportedVersionError(this.version, this.minimum)
      : super('Unsupported server version $version, the minimum is $minimum');

  final String version;
  final String minimum;
}

/// Thrown when the HTTP engine receives a non success status code.
class HttpConnectionError extends SurrealError {
  const HttpConnectionError(super.message, {required this.statusCode});

  final int statusCode;
}
