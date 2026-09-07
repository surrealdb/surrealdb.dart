/// Base class for every error raised by the AgentMemory client.
///
/// Follows the RFC 7807 Problem Details shape returned by the AgentMemory API.
class AgentMemoryError implements Exception {
  const AgentMemoryError({
    required this.status,
    required this.title,
    this.detail,
    this.type,
    this.instance,
    this.extensions = const {},
  });

  /// The HTTP status code, or 0 for a connection level failure.
  final int status;

  /// A short summary of the problem.
  final String title;

  /// A longer explanation, when the server provides one.
  final String? detail;

  /// A URI identifying the problem type.
  final String? type;

  /// A URI identifying the specific occurrence.
  final String? instance;

  /// Any additional members returned in the problem document.
  final Map<String, dynamic> extensions;

  @override
  String toString() =>
      'AgentMemoryError($status, $title${detail == null ? '' : ', $detail'})';
}

/// Authentication failed or is missing (HTTP 401).
class AuthError extends AgentMemoryError {
  const AuthError({required super.title, super.detail, super.extensions})
      : super(status: 401);
}

/// The caller lacks the scope or grant required (HTTP 403).
class ScopeError extends AgentMemoryError {
  const ScopeError({required super.title, super.detail, super.extensions})
      : super(status: 403);
}

/// The requested resource does not exist (HTTP 404).
class NotFoundError extends AgentMemoryError {
  const NotFoundError({required super.title, super.detail, super.extensions})
      : super(status: 404);
}

/// The request was rejected as invalid (HTTP 400 or 422).
class ValidationError extends AgentMemoryError {
  const ValidationError({
    required super.status,
    required super.title,
    super.detail,
    super.extensions,
  });
}

/// The caller is being rate limited (HTTP 429).
class RateLimitError extends AgentMemoryError {
  const RateLimitError({
    required super.title,
    super.detail,
    super.extensions,
    this.retryAfter,
  }) : super(status: 429);

  /// How long to wait before retrying, when the server says so.
  final Duration? retryAfter;
}

/// The server failed to handle the request (HTTP 5xx).
class ServerError extends AgentMemoryError {
  const ServerError({
    required super.status,
    required super.title,
    super.detail,
    super.extensions,
  });
}

/// A network level failure, such as a timeout or a refused connection.
class ConnectionError extends AgentMemoryError {
  const ConnectionError({required super.title, super.detail})
      : super(status: 0);
}

/// Builds the right [AgentMemoryError] subclass from a response.
AgentMemoryError errorFromResponse(
  int status,
  Map<String, dynamic> body, {
  Duration? retryAfter,
}) {
  final title = (body['title'] ?? 'Request failed').toString();
  final detail = body['detail']?.toString();
  final type = body['type']?.toString();
  final instance = body['instance']?.toString();
  final reserved = {'title', 'detail', 'type', 'instance', 'status'};
  final extensions = <String, dynamic>{
    for (final entry in body.entries)
      if (!reserved.contains(entry.key)) entry.key: entry.value,
  };

  switch (status) {
    case 401:
      return AuthError(title: title, detail: detail, extensions: extensions);
    case 403:
      return ScopeError(title: title, detail: detail, extensions: extensions);
    case 404:
      return NotFoundError(
          title: title, detail: detail, extensions: extensions);
    case 400:
    case 422:
      return ValidationError(
          status: status, title: title, detail: detail, extensions: extensions);
    case 429:
      return RateLimitError(
          title: title,
          detail: detail,
          extensions: extensions,
          retryAfter: retryAfter);
  }
  if (status >= 500) {
    return ServerError(
        status: status, title: title, detail: detail, extensions: extensions);
  }
  return AgentMemoryError(
    status: status,
    title: title,
    detail: detail,
    type: type,
    instance: instance,
    extensions: extensions,
  );
}
