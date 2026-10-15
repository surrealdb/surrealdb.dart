@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  const fastReconnect = ReconnectOptions(
    attempts: 3,
    retryDelay: Duration(milliseconds: 10),
    retryDelayMax: Duration(milliseconds: 10),
  );

  setUp(() async {
    server = await FakeSurrealServer.start();
    db = Surreal();
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('reconnects with a single socket and restores the session', () async {
    await db.connect(server.url,
        options: const ConnectOptions(reconnect: fastReconnect));
    await db.use(namespace: 'ns', database: 'db');
    await db.authenticate('token');

    await server.dropAll();
    await eventually(
        () => db.status == ConnectionStatus.connected && server.accepted == 2);

    expect(server.openConnections, 1);
    expect(server.methods.skip(3), ['use', 'authenticate']);
    expect(db.accessToken, 'token');
  });

  test('an expired token does not break the reconnect', () async {
    await db.connect(server.url,
        options: const ConnectOptions(reconnect: fastReconnect));
    await db.authenticate('expired');

    server.handler = (request) => request.method == 'authenticate'
        ? const FakeError('The token has expired')
        : FakeSurrealServer.defaultReply(request);
    await server.dropAll();
    await eventually(
        () => db.status == ConnectionStatus.connected && server.accepted == 2);

    // One attempt was enough: the rejected token is dropped rather than
    // retried, and no socket is left behind.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.accepted, 2);
    expect(server.openConnections, 1);
    expect(db.accessToken, isNull);
    await db.query('RETURN 1');
  });

  test('failed attempts close the sockets they opened', () async {
    await db.connect(server.url,
        options: const ConnectOptions(reconnect: fastReconnect));
    await db.use(namespace: 'ns', database: 'db');

    server.handler = (request) => request.method == 'use'
        ? const FakeError('Temporarily unavailable')
        : FakeSurrealServer.defaultReply(request);
    await server.dropAll();
    await eventually(() => db.status == ConnectionStatus.disconnected);
    await eventually(() => server.openConnections == 0);
    expect(server.accepted, 4);
  });
}
