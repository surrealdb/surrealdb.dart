@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

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

  test('a timed out session change starts again on a new socket', () async {
    await db.connect(server.url,
        options: const ConnectOptions(
          versionCheck: false,
          requestTimeout: Duration(milliseconds: 300),
          reconnect: ReconnectOptions(
            retryDelay: Duration(milliseconds: 10),
            retryDelayMax: Duration(milliseconds: 10),
          ),
        ));
    await db.use(namespace: 'a', database: 'b');
    server.handler = (request) =>
        request.method == 'use' && request.params.first == 'c'
            ? const FakeSilence()
            : FakeSurrealServer.defaultReply(request);

    await expectLater(db.use(namespace: 'c', database: 'd'),
        throwsA(isA<RequestTimeoutError>()));
    // The server may or may not have switched, so the session it is known to
    // have is restored on a new socket.
    await eventually(
        () => server.accepted == 2 && db.status == ConnectionStatus.connected);
    expect(server.requests.last.method, 'use');
    expect(server.requests.last.params, ['a', 'b']);
  });

  test('requests do not time out unless the caller asks for it', () {
    expect(const ConnectOptions().requestTimeout, isNull);
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

  test('a timed out HTTP request is aborted', () async {
    // A server that accepts connections and never answers them.
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);
    var accepted = 0;
    var open = 0;
    silent.listen((socket) {
      accepted++;
      open++;
      socket.listen((_) {},
          onDone: () {
            open--;
            socket.destroy();
          },
          onError: (_) => open--);
    });

    await db.connect('http://127.0.0.1:${silent.port}/rpc',
        options: const ConnectOptions(
            versionCheck: false, requestTimeout: Duration(milliseconds: 300)));
    await expectLater(
        db.query('RETURN 1'), throwsA(isA<RequestTimeoutError>()));
    expect(accepted, 1);
    // The client closed the connection rather than leaving it waiting.
    await eventually(() => open == 0);
  });
}
