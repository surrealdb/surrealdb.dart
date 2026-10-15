@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;
  final txnId = Uuid('0192e3c4-0000-7000-8000-000000000001');

  setUp(() async {
    server = await FakeSurrealServer.start();
    server.handler = (r) => r.method == 'begin'
        ? FakeResult(txnId)
        : FakeSurrealServer.defaultReply(r);
    db = Surreal();
    await db.connect(server.url,
        options: const ConnectOptions(
          versionCheck: false,
          reconnect: ReconnectOptions(
            retryDelay: Duration(milliseconds: 10),
            retryDelayMax: Duration(milliseconds: 10),
          ),
        ));
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  FakeRequest last(String method) =>
      server.requests.lastWhere((r) => r.method == method);

  group('sessions', () {
    test('a new session is attached and its calls carry its id', () async {
      final session = await db.newSession();
      expect(last('attach').raw['session'], session.id);

      await session.use(namespace: 'ns', database: 'db');
      await session.query('RETURN 1');
      expect(last('use').raw['session'], session.id);
      expect(last('query').raw['session'], session.id);
      expect(session.namespace, 'ns');
      // The default session is untouched.
      expect(db.namespace, isNull);

      await db.query('RETURN 2');
      expect(last('query').raw.containsKey('session'), isFalse);
    });

    test('a fork starts as a copy of its parent', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.set('x', 1);
      await db.authenticate('token', refreshToken: 'refresh');
      server.requests.clear();

      final fork = await db.forkSession();
      expect(
        [
          for (final r in server.requests) [r.method, ...r.params]
        ],
        [
          ['attach'],
          ['use', 'ns', 'db'],
          ['let', 'x', 1],
          ['authenticate', 'token'],
        ],
      );
      expect(server.requests.every((r) => r.raw['session'] == fork.id), isTrue);
      // The refresh token can be used once, so it stays with the parent.
      expect(fork.tokens, const Tokens(access: 'token'));
      expect(db.tokens, const Tokens(access: 'token', refresh: 'refresh'));
      expect(fork.variables, {'x': 1});

      // From then on the two are independent.
      await fork.set('y', 2);
      expect(db.variables, {'x': 1});
    });

    test('attached sessions are attached again after a reconnect', () async {
      final session = await db.newSession();
      await session.use(namespace: 'ns', database: 'db');
      await session.set('x', 1);
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);

      expect(
        [
          for (final r in server.requests)
            [r.method, r.raw['session'] == session.id, ...r.params],
        ],
        [
          ['attach', true],
          ['use', true, 'ns', 'db'],
          ['let', true, 'x', 1],
        ],
      );
    });

    test('a closed session is detached and can no longer be used', () async {
      final session = await db.newSession();
      await session.close();
      expect(last('detach').raw['session'], session.id);
      expect(session.isClosed, isTrue);
      expect(
          () => session.query('RETURN 1'), throwsA(isA<InvalidSessionError>()));

      server.requests.clear();
      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, isNot(contains('attach')));
    });

    test('a closed session cannot be forked or watch a live query', () async {
      final session = await db.newSession();
      await session.close();
      expect(() => session.forkSession(), throwsA(isA<InvalidSessionError>()));
      expect(
          () => session.liveOf(Uuid.v4()), throwsA(isA<InvalidSessionError>()));
    });

    test('an attached session renews its own tokens', () async {
      var issued = 0;
      server.handler = (r) => switch (r.method) {
            'signin' || 'refresh' => FakeResult({
                'access': fakeJwt(
                    Duration(seconds: r.method == 'signin' ? 2 : 3600),
                    id: '${++issued}'),
                'refresh': 'refresh-$issued',
              }),
            _ => FakeSurrealServer.defaultReply(r),
          };
      final session = await db.newSession();
      await session.signin(const RootAuth(username: 'u', password: 'p'));

      await eventually(() => server.methods.contains('refresh'),
          timeout: const Duration(seconds: 3));
      expect(last('refresh').raw['session'], session.id);
      await eventually(() => session.tokens?.refresh == 'refresh-2');
      // The default session has no tokens of its own to renew.
      expect(db.tokens, isNull);
      await session.close();
    });

    test('a session closed during a reconnect is not left attached', () async {
      final session = await db.newSession();
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'attach' && server.accepted == 2 && held == null) {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      await server.dropAll();
      await eventually(() => held != null);

      await session.close();
      held!.socket
          .add(const CborCodec().encode({'id': held!.id, 'result': null}));
      await eventually(() => db.status == ConnectionStatus.connected);
      await eventually(() => server.requests.any((r) =>
          r.method == 'detach' &&
          r.raw['session'] == session.id &&
          identical(r.socket, held!.socket)));
    });

    test('a fork renews with its parent\'s credentials, not its refresh token',
        () async {
      var issued = 0;
      server.handler = (r) => switch (r.method) {
            'signin' => FakeResult(
                fakeJwt(const Duration(seconds: 2), id: '${++issued}')),
            _ => FakeSurrealServer.defaultReply(r),
          };
      final parent = Surreal();
      addTearDown(parent.close);
      await parent.connect(server.url,
          options: const ConnectOptions(
              versionCheck: false,
              authentication: RootAuth(username: 'u', password: 'p')));
      final fork = await parent.forkSession();
      await eventually(
          () => server.requests
              .any((r) => r.method == 'signin' && r.raw['session'] == fork.id),
          timeout: const Duration(seconds: 3));
      expect(server.methods, isNot(contains('refresh')));
    });

    test('a kill from another session leaves the query alone', () async {
      final session = await db.newSession();
      final live = await db.live('person');
      await session.kill(live.id);
      expect(last('kill').raw['session'], session.id);

      final received = live.stream.first;
      server.push({
        'result': {
          'id': live.id,
          'action': 'CREATE',
          'result': {'id': const RecordId('person', 1)},
        },
      });
      expect((await received.timeout(const Duration(seconds: 2))).action,
          LiveAction.create);
      await session.close();
    });

    test('closing the client closes its sessions', () async {
      final session = await db.newSession();
      await db.close();
      expect(session.isClosed, isTrue);
    });

    test('lists sessions', () async {
      final id = Uuid('0192e3c4-0000-4000-8000-000000000002');
      server.handler = (r) => r.method == 'sessions'
          ? FakeResult([id])
          : FakeSurrealServer.defaultReply(r);
      expect(await db.sessions(), [id]);
    });

    test('live queries run in, and restart in, their session', () async {
      final session = await db.newSession();
      await session.live('person');
      expect(last('live').raw['session'], session.id);
      server.requests.clear();

      await server.dropAll();
      await eventually(() => server.methods.contains('live'));
      expect(last('live').raw['session'], session.id);
    });
  });

  group('transactions', () {
    test('calls in a transaction carry its id', () async {
      final txn = await db.beginTransaction();
      expect(txn.id, txnId);

      await txn.create(const RecordId('person', 1), {'name': 'a'});
      expect(last('create').raw['txn'], txnId);
      expect(last('create').raw.containsKey('session'), isFalse);

      await txn.commit();
      expect(last('commit').params, [txnId]);
      expect(txn.isDone, isTrue);
      expect(
          () => txn.query('RETURN 1'), throwsA(isA<TransactionClosedError>()));
      expect(() => txn.cancel(), throwsA(isA<TransactionClosedError>()));
    });

    test('cancel sends the transaction id', () async {
      final txn = await db.beginTransaction();
      await txn.cancel();
      expect(last('cancel').params, [txnId]);
    });

    test('a transaction in a session carries both ids', () async {
      final session = await db.newSession();
      final txn = await session.beginTransaction();
      expect(last('begin').raw['session'], session.id);
      await txn.query('RETURN 1');
      expect(last('query').raw['session'], session.id);
      expect(last('query').raw['txn'], txnId);
      await txn.commit();
      expect(last('commit').raw['session'], session.id);
    });
  });
}
