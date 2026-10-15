@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late HttpServer server;
  late Surreal db;
  final methods = <String>[];
  final fresh = fakeJwt(const Duration(hours: 1), id: 'fresh');

  setUp(() async {
    methods.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final call = jsonDecode(await utf8.decodeStream(request)) as Map;
      final method = call['method'] as String;
      methods.add(method);
      final reply = switch (method) {
        'authenticate' when (call['params'] as List).first == 'revoked' => {
            'error': {
              'code': -32002,
              'message': 'The token is not valid',
              'kind': 'NotAllowed',
            },
          },
        'refresh' => {
            'result': {'access': fresh, 'refresh': 'refresh-2'},
          },
        _ => {'result': null},
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'id': call['id'], ...reply}));
      await request.response.close();
    });
    db = Surreal();
    await db.connect('http://127.0.0.1:${server.port}/rpc',
        options: const ConnectOptions(
            versionCheck: false, format: SurrealFormat.json));
  });

  tearDown(() async {
    await db.close();
    await server.close(force: true);
  });

  test('a token the server rejects is refreshed over HTTP too', () async {
    await db.authenticate('revoked', refreshToken: 'refresh-1');
    expect(methods, ['authenticate', 'refresh']);
    expect(db.tokens, Tokens(access: fresh, refresh: 'refresh-2'));
  });

  test('a token the server rejects fails authenticate over HTTP', () async {
    await expectLater(
        db.authenticate('revoked'), throwsA(isA<NotAllowedError>()));
    expect(db.tokens, isNull);
  });
}
