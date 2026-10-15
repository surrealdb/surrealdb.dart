@TestOn('vm')
library;

import 'dart:async';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  setUp(() async {
    server = await FakeSurrealServer.start();
    db = Surreal();
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('a request with no reply fails after the request timeout', () async {
    await db.connect(server.url,
        options: const ConnectOptions(
            versionCheck: false, requestTimeout: Duration(milliseconds: 300)));
    server.handler = (request) => request.method == 'query'
        ? const FakeSilence()
        : FakeSurrealServer.defaultReply(request);

    await expectLater(
      db.query('SLEEP 1h'),
      throwsA(isA<RequestTimeoutError>()
          .having((e) => e.method, 'method', 'query')),
    );

    // The connection is still usable afterwards.
    server.handler = FakeSurrealServer.defaultReply;
    await db.query('RETURN 1');
  });

  test('a null request timeout waits for the reply', () async {
    await db.connect(server.url,
        options: const ConnectOptions(requestTimeout: null));
    server.handler = (request) => request.method == 'query'
        ? const FakeSilence()
        : FakeSurrealServer.defaultReply(request);

    var completed = false;
    unawaited(
        db.query('SLEEP 1h').then((_) => completed = true, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(completed, isFalse);
  });
}
