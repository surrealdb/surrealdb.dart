@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Surreal db;
  var echoId = true;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final call = jsonDecode(await utf8.decodeStream(request)) as Map;
      request.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          if (echoId) 'id': call['id'],
          'error': {
            'code': -32002,
            'message': 'Not allowed',
            'kind': 'NotAllowed'
          },
        }));
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

  test("the server's own error is thrown", () async {
    echoId = true;
    await expectLater(db.query('RETURN 1'), throwsA(isA<NotAllowedError>()));
  });

  test("an error body that is not the server's reply keeps the status",
      () async {
    echoId = false;
    await expectLater(
        db.query('RETURN 1'),
        throwsA(isA<HttpConnectionError>()
            .having((e) => e.statusCode, 'statusCode', 401)));
  });
}
