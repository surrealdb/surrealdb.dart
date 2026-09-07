import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'idempotency.dart';

/// The client version reported in the `User-Agent` header.
const String agentMemoryClientVersion = '0.1.0';

/// The backoff schedule, in milliseconds, applied between retries.
const List<int> backoffSchedule = [250, 500, 1000];

/// Configuration for a [AgentMemoryTransport].
class TransportOptions {
  const TransportOptions({
    required this.endpoint,
    required this.apiKey,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.onBehalfOf,
    this.client,
  });

  /// The origin of the AgentMemory service, without a trailing slash.
  final String endpoint;

  /// The API key sent as a bearer token.
  final String apiKey;

  /// How long to wait for a response before failing.
  final Duration timeout;

  /// The maximum number of retries for idempotent requests.
  final int maxRetries;

  /// A principal id to act on behalf of, added as a header.
  final String? onBehalfOf;

  /// The HTTP client to use. One is created if not supplied.
  final http.Client? client;

  TransportOptions copyWith({String? onBehalfOf}) => TransportOptions(
        endpoint: endpoint,
        apiKey: apiKey,
        timeout: timeout,
        maxRetries: maxRetries,
        onBehalfOf: onBehalfOf ?? this.onBehalfOf,
        client: client,
      );
}

/// Handles the HTTP details of talking to the AgentMemory API: headers, retries,
/// idempotency keys, error mapping, and server sent event streams.
class AgentMemoryTransport {
  AgentMemoryTransport(this.options)
      : _client = options.client ?? http.Client();

  final TransportOptions options;
  final http.Client _client;

  /// Sends a request with a JSON body and decodes the JSON response. Returns
  /// null for an empty or 204 response.
  Future<Object?> request({
    required String method,
    required String path,
    Map<String, String>? query,
    Object? body,
    bool idempotent = false,
  }) async {
    final uri = _uri(path, query);
    final bodyString = body == null ? null : jsonEncode(body);
    final canRetry = idempotent || method == 'GET' || method == 'HEAD';

    var attempt = 0;
    while (true) {
      try {
        final request = http.Request(method, uri)
          ..headers.addAll(_headers(
            hasJsonBody: bodyString != null,
            idempotencyKey: idempotent
                ? idempotencyKey(method, path, bodyString ?? '')
                : null,
          ));
        if (bodyString != null) request.body = bodyString;

        final response = await http.Response.fromStream(
          await _client.send(request).timeout(options.timeout),
        );
        if (response.statusCode >= 400) throw _errorFor(response);
        if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
          return null;
        }
        return jsonDecode(utf8.decode(response.bodyBytes));
      } on AgentMemoryError catch (error) {
        if (!_retryable(canRetry, error.status) ||
            attempt >= options.maxRetries) {
          rethrow;
        }
      } on TimeoutException {
        if (!canRetry || attempt >= options.maxRetries) {
          throw const ConnectionError(title: 'Request timed out');
        }
      } catch (error) {
        if (!canRetry || attempt >= options.maxRetries) {
          throw ConnectionError(
              title: 'Connection failed', detail: error.toString());
        }
      }
      await Future<void>.delayed(_backoff(attempt));
      attempt++;
    }
  }

  /// Sends a multipart upload. The [metadata] part is written before the file
  /// part, as the server requires.
  Future<Object?> upload({
    required String path,
    required Map<String, dynamic> metadata,
    required List<int> bytes,
    required String filename,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path, null))
      ..headers.addAll(_headers(hasJsonBody: false))
      ..fields['metadata'] = jsonEncode(metadata)
      ..files
          .add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(options.timeout),
    );
    if (response.statusCode >= 400) throw _errorFor(response);
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  /// Opens a server sent event stream. The returned stream yields the raw
  /// bytes of the response body.
  Future<Stream<List<int>>> stream({
    required String method,
    required String path,
    Object? body,
  }) async {
    final request = http.Request(method, _uri(path, null))
      ..headers.addAll(_headers(
        hasJsonBody: body != null,
        accept: 'text/event-stream',
      ));
    if (body != null) request.body = jsonEncode(body);
    final response = await _client.send(request);
    if (response.statusCode >= 400) {
      final full = await http.Response.fromStream(response);
      throw _errorFor(full);
    }
    return response.stream;
  }

  /// Returns the raw bytes of a response, for endpoints that do not return
  /// JSON.
  Future<List<int>> bytes({
    required String method,
    required String path,
  }) async {
    final response = await _client
        .get(_uri(path, null), headers: _headers(hasJsonBody: false))
        .timeout(options.timeout);
    if (response.statusCode >= 400) throw _errorFor(response);
    return response.bodyBytes;
  }

  /// Releases the underlying HTTP client.
  void close() => _client.close();

  Uri _uri(String path, Map<String, String>? query) {
    final base = Uri.parse('${options.endpoint}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  Map<String, String> _headers({
    required bool hasJsonBody,
    String accept = 'application/json',
    String? idempotencyKey,
  }) =>
      {
        'Authorization': 'Bearer ${options.apiKey}',
        'Accept': accept,
        'User-Agent': 'surrealdb-memory-dart/$agentMemoryClientVersion',
        if (hasJsonBody) 'Content-Type': 'application/json',
        if (options.onBehalfOf != null)
          'X-Spectron-On-Behalf-Of': options.onBehalfOf!,
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      };

  bool _retryable(bool canRetry, int status) =>
      canRetry && (status == 0 || status >= 500);

  Duration _backoff(int attempt) {
    final index =
        attempt < backoffSchedule.length ? attempt : backoffSchedule.length - 1;
    return Duration(milliseconds: backoffSchedule[index]);
  }

  AgentMemoryError _errorFor(http.Response response) {
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      body = decoded is Map<String, dynamic> ? decoded : {'title': '$decoded'};
    } catch (_) {
      body = {'title': 'Request failed'};
    }
    Duration? retryAfter;
    final header = response.headers['retry-after'];
    if (header != null) {
      final seconds = int.tryParse(header);
      if (seconds != null) retryAfter = Duration(seconds: seconds);
    }
    return errorFromResponse(response.statusCode, body, retryAfter: retryAfter);
  }
}
