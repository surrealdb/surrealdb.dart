import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:surrealdb/memory.dart';
import 'package:test/test.dart';

Map<String, String> _lowerKeys(Map<String, String> headers) =>
    {for (final entry in headers.entries) entry.key.toLowerCase(): entry.value};

void main() {
  group('AgentMemory transport', () {
    test('sends auth and idempotency headers on remember', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'mode': 'full'}), 200,
            headers: {'content-type': 'application/json'});
      });

      final memory = AgentMemory(
        endpoint: 'https://memory.test',
        context: 'acme',
        apiKey: 'secret',
        httpClient: client,
      );

      await memory.remember('hello', scopes: 'user/tobie');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/v1/acme/facts');
      final headers = _lowerKeys(captured.headers);
      expect(headers['authorization'], 'Bearer secret');
      expect(headers['idempotency-key'], isNotNull);

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['text'], 'hello');
      expect(body['scopes'], [
        ['user/tobie'],
      ]);
    });

    test('retries retryable requests on server errors', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls < 3) return http.Response('{"title":"boom"}', 500);
        return http.Response(jsonEncode({'identity': {}}), 200,
            headers: {'content-type': 'application/json'});
      });

      final memory = AgentMemory(
        endpoint: 'https://memory.test',
        context: 'acme',
        apiKey: 'secret',
        httpClient: client,
      );

      final result = await memory.state();
      expect(result, isA<Map<String, dynamic>>());
      expect(calls, 3);
    });

    test('maps a 404 to NotFoundError', () async {
      final client = MockClient(
          (request) async => http.Response('{"title":"missing"}', 404));

      final memory = AgentMemory(
        endpoint: 'https://memory.test',
        context: 'acme',
        apiKey: 'secret',
        httpClient: client,
      );

      expect(
        () => memory.documents.get('nope'),
        throwsA(isA<NotFoundError>()),
      );
    });

    test('does not retry non idempotent requests', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{"title":"boom"}', 500);
      });

      final memory = AgentMemory(
        endpoint: 'https://memory.test',
        context: 'acme',
        apiKey: 'secret',
        httpClient: client,
      );

      await expectLater(
        memory.documents.delete('id'),
        throwsA(isA<ServerError>()),
      );
      expect(calls, 1);
    });
  });
}
