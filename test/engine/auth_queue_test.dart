@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Surreal db;
  late String url;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/rpc';
    server.listen((request) async {
      final call = jsonDecode(await utf8.decodeStream(request)) as Map;
      // A sign-in that never answers, so the calls behind it wait.
      if (call['method'] == 'signin') return;
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'id': call['id'], 'result': null}));
      await request.response.close();
    });
    db = Surreal();
  });

  tearDown(() async {
    await db.close();
    await server.close(force: true);
  });

  test('calls queued before close do not reach the next connection', () async {
    const options = ConnectOptions(
        versionCheck: false,
        format: SurrealFormat.json,
        requestTimeout: Duration(milliseconds: 300));
    await db.connect(url, options: options);
    unawaited(db
        .signin(const RootAuth(username: 'u', password: 'p'))
        .then((_) {}, onError: (_) {}));
    final using = db.use(namespace: 'old', database: 'old');
    await db.connect(url, options: options);
    await expectLater(using, throwsA(isA<ConnectionUnavailableError>()));
    expect(db.namespace, isNull);
  });
}
