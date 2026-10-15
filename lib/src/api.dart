part of 'surreal.dart';

/// Calls the custom APIs defined on the database with `DEFINE API`, from
/// the session or transaction it was taken from. Needs SurrealDB 3.0 or
/// later.
///
/// The call runs the API's handler on the server through `api::invoke`, so
/// it works over every engine and carries the session's authentication.
///
/// ```dart
/// final response = await db.api.get('/users/tobie', query: {'full': 'true'});
/// print(response.status);
/// print(response.value()); // the body, or an UnsuccessfulApiError
///
/// final authed = db.api.header('x-tenant', 'acme');
/// await authed.post('/orders', body: {'item': 'book'});
/// ```
final class SurrealApi {
  const SurrealApi._(this._target, this._headers);

  final SurrealQueryable _target;
  final Map<String, String> _headers;

  /// A copy that sends [name] with every call, or no longer sends it when
  /// [value] is null. Header names are not case sensitive, and are sent in
  /// lower case.
  SurrealApi header(String name, String? value) => SurrealApi._(_target, {
        for (final entry in _headers.entries)
          if (entry.key != name.toLowerCase()) entry.key: entry.value,
        if (value != null) name.toLowerCase(): value,
      });

  /// Calls [path] with the HTTP [method], such as `get` or `post`.
  Future<ApiResponse> invoke(
    String path, {
    String method = 'get',
    Object? body = const _NoBody(),
    Map<String, String>? headers,
    Map<String, String>? query,
  }) async {
    final [result] = await _target.query(
      r'RETURN api::invoke($path, $request)',
      bindings: {
        'path': path,
        'request': {
          'method': method.toLowerCase(),
          'headers': {
            ..._headers,
            // These replace the ones set with [header], whatever their case.
            for (final MapEntry(:key, :value) in (headers ?? const {}).entries)
              key.toLowerCase(): value,
          },
          // Empty rather than left out, as for a request over HTTP.
          'query': query ?? const <String, String>{},
          // An explicit null is sent as NULL; a body left out arrives as NONE.
          if (body is! _NoBody) 'body': body,
        },
      },
    );
    return ApiResponse._from(result);
  }

  /// Calls [path] with `GET`.
  Future<ApiResponse> get(String path,
          {Map<String, String>? headers, Map<String, String>? query}) =>
      invoke(path, method: 'get', headers: headers, query: query);

  /// Calls [path] with `POST`.
  Future<ApiResponse> post(String path,
          {Object? body = const _NoBody(),
          Map<String, String>? headers,
          Map<String, String>? query}) =>
      invoke(path, method: 'post', body: body, headers: headers, query: query);

  /// Calls [path] with `PUT`.
  Future<ApiResponse> put(String path,
          {Object? body = const _NoBody(),
          Map<String, String>? headers,
          Map<String, String>? query}) =>
      invoke(path, method: 'put', body: body, headers: headers, query: query);

  /// Calls [path] with `PATCH`.
  Future<ApiResponse> patch(String path,
          {Object? body = const _NoBody(),
          Map<String, String>? headers,
          Map<String, String>? query}) =>
      invoke(path, method: 'patch', body: body, headers: headers, query: query);

  /// Calls [path] with `DELETE`.
  Future<ApiResponse> delete(String path,
          {Object? body = const _NoBody(),
          Map<String, String>? headers,
          Map<String, String>? query}) =>
      invoke(path,
          method: 'delete', body: body, headers: headers, query: query);

  /// Calls [path] with `TRACE`.
  Future<ApiResponse> trace(String path,
          {Object? body = const _NoBody(),
          Map<String, String>? headers,
          Map<String, String>? query}) =>
      invoke(path, method: 'trace', body: body, headers: headers, query: query);
}

/// Marks a body that was left out, as distinct from an explicit null.
final class _NoBody {
  const _NoBody();
}

/// The response from a [SurrealApi] call.
final class ApiResponse {
  const ApiResponse({required this.status, this.headers = const {}, this.body});

  factory ApiResponse._from(Object? result) {
    final map = result is Map ? result : const {};
    final status = map['status'];
    final headers = map['headers'];
    final body = map['body'];
    return ApiResponse(
      status: status is int ? status : 200,
      headers: headers is Map
          ? {
              for (final e in headers.entries)
                e.key.toString().toLowerCase(): e.value.toString(),
            }
          : const {},
      body: body,
    );
  }

  /// The HTTP status the API returned.
  final int status;

  /// The headers the API returned, with their names in lower case, as
  /// header names are not case sensitive.
  final Map<String, String> headers;

  /// The body the API returned: [none] when it returned no body, as distinct
  /// from an explicit null.
  final Object? body;

  /// Whether [status] is in the 2xx range.
  bool get ok => status >= 200 && status < 300;

  /// The [body], or an [UnsuccessfulApiError] when the call did not succeed.
  Object? value() {
    if (!ok) throw UnsuccessfulApiError(status, body);
    return body;
  }

  @override
  String toString() => 'ApiResponse($status, $body)';
}
