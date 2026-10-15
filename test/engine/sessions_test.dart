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

  /// Sends the reply to a request whose reply was held back.
  void reply(FakeRequest request,
          {Object? result, Map<String, Object?>? error}) =>
      request.socket.add(const CborCodec().encode({
        'id': request.id,
        if (error != null) 'error': error else 'result': result,
      }));

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
          ['let', 'x', 1],
          ['authenticate', 'token'],
          ['use', 'ns', 'db'],
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

    test('a fork keeps its parent\'s selection over the token\'s', () async {
      final token = fakeJwt(const Duration(hours: 1), claims: {'NS': 'ns'});
      await db.authenticate(token);
      await db.use(namespace: 'other', database: 'db');
      final fork = await db.forkSession();
      expect(last('use').params, ['other', 'db']);
      expect([fork.namespace, fork.database], ['other', 'db']);

      await db.use(namespace: null);
      final cleared = await db.forkSession();
      expect(last('use').params, [null, null]);
      expect([cleared.namespace, cleared.database], [null, null]);
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

    test('a fork whose token is rejected on reconnect signs in again',
        () async {
      var issued = 0;
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}'))
          : FakeSurrealServer.defaultReply(r);
      final parent = Surreal();
      addTearDown(parent.close);
      await parent.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      final fork = await parent.forkSession();
      server.handler = (r) => switch (r.method) {
            'authenticate' => const FakeError('The token has expired',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            'signin' =>
              FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}')),
            _ => FakeSurrealServer.defaultReply(r),
          };
      server.requests.clear();

      await server.dropAll();
      await eventually(() => server.requests
          .any((r) => r.method == 'signin' && r.raw['session'] == fork.id));
      await eventually(() => parent.status == ConnectionStatus.connected);
      expect(fork.tokens, isNotNull);
      expect(parent.tokens, isNotNull);
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

    test('liveOf will not share a query of another session', () async {
      final session = await db.newSession();
      final live = await db.live('person');
      expect(() => session.liveOf(live.id), throwsA(isA<SurrealError>()));
      expect(db.liveOf(live.id), same(live));
      await session.close();
    });

    test('a timed out attach starts again on a new socket', () async {
      final timed = Surreal();
      addTearDown(timed.close);
      await timed.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            requestTimeout: Duration(milliseconds: 300),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      final before = server.accepted;
      server.handler = (r) => r.method == 'attach'
          ? const FakeSilence()
          : FakeSurrealServer.defaultReply(r);
      await expectLater(
          timed.newSession(), throwsA(isA<RequestTimeoutError>()));
      await eventually(() =>
          server.accepted == before + 1 &&
          timed.status == ConnectionStatus.connected);
    });

    test('a session whose detach is refused stays open', () async {
      final session = await db.newSession();
      server.handler = (r) => r.method == 'detach'
          ? const FakeError('There was a problem with the datastore',
              extra: {'kind': 'Internal'})
          : FakeSurrealServer.defaultReply(r);
      await expectLater(session.close(), throwsA(isA<ServerError>()));
      expect(session.isClosed, isFalse);
      server.requests.clear();

      await server.dropAll();
      await eventually(() => server.requests
          .any((r) => r.method == 'attach' && r.raw['session'] == session.id));
    });

    test('a session whose detach times out is cleaned up', () async {
      final timed = Surreal();
      addTearDown(timed.close);
      await timed.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            requestTimeout: Duration(milliseconds: 300),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      final session = await timed.newSession();
      final live = await session.live('person');
      final before = server.accepted;
      server.handler = (r) => r.method == 'detach'
          ? const FakeSilence()
          : FakeSurrealServer.defaultReply(r);
      await session.close();
      expect(session.isClosed, isTrue);
      await live.stream.toList();
      await eventually(() =>
          server.accepted == before + 1 &&
          timed.status == ConnectionStatus.connected);
      expect(
          server.requests.where(
              (r) => r.method == 'attach' && r.raw['session'] == session.id),
          hasLength(1));
    });

    test('a session closed while a later one is restored is detached',
        () async {
      final first = await db.newSession();
      final second = await db.newSession();
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'attach' &&
            r.raw['session'] == second.id &&
            server.accepted == 2 &&
            held == null) {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      await server.dropAll();
      await eventually(() => held != null);

      await first.close();
      reply(held!);
      await eventually(() => db.status == ConnectionStatus.connected);
      expect(
          server.requests.any((r) =>
              r.method == 'detach' &&
              r.raw['session'] == first.id &&
              identical(r.socket, held!.socket)),
          isTrue);
    });

    test('a live query that starts as its session closes is not kept',
        () async {
      final session = await db.newSession();
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'live') {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final starting = session.live('person');
      await eventually(() => held != null);
      await session.close();
      reply(held!, result: Uuid('0192e3c4-0000-7000-8000-0000000000aa'));
      await expectLater(starting, throwsA(isA<InvalidSessionError>()));
    });

    test('a transaction begun as its session resets or closes fails', () async {
      final session = await db.newSession();
      final held = <FakeRequest>[];
      server.handler = (r) {
        if (r.method == 'begin') {
          held.add(r);
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final reset = db.beginTransaction();
      final closed = session.beginTransaction();
      await eventually(() => held.length == 2);
      await db.reset();
      await session.close();
      for (final request in held) {
        reply(request, result: txnId);
      }
      await expectLater(reset, throwsA(isA<TransactionClosedError>()));
      await expectLater(closed, throwsA(isA<InvalidSessionError>()));
    });

    test('a transaction begun as a refused reset or close runs keeps going',
        () async {
      final session = await db.newSession();
      final held = <FakeRequest>[];
      server.handler = (r) => switch (r.method) {
            'begin' => () {
                held.add(r);
                return const FakeSilence();
              }(),
            'reset' || 'detach' => const FakeError(
                'There was a problem with the datastore',
                extra: {'kind': 'Internal'}),
            _ => FakeSurrealServer.defaultReply(r),
          };
      final onClient = db.beginTransaction();
      final onSession = session.beginTransaction();
      await eventually(() => held.length == 2);
      await expectLater(db.reset(), throwsA(isA<ServerError>()));
      await expectLater(session.close(), throwsA(isA<ServerError>()));
      for (final request in held) {
        reply(request, result: txnId);
      }
      expect((await onClient).id, txnId);
      expect((await onSession).id, txnId);
      expect(server.methods, isNot(contains('cancel')));
    });

    test('a transaction begun as a reset runs is cancelled', () async {
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'begin') {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final beginning = db.beginTransaction();
      await eventually(() => held != null);
      await db.reset();
      reply(held!, result: txnId);
      await expectLater(beginning, throwsA(isA<TransactionClosedError>()));
      expect(last('cancel').params, [txnId]);
    });

    test('a live query started as a reset runs is killed', () async {
      final queryId = Uuid('0192e3c4-0000-7000-8000-0000000000bb');
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'live') {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final starting = db.live('person');
      await eventually(() => held != null);
      await db.reset();
      reply(held!, result: queryId);
      await expectLater(starting, throwsA(isA<SurrealError>()));
      expect(last('kill').params, [queryId]);
    });

    test('a second close waits for the first', () async {
      final session = await db.newSession();
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'detach') {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final first = session.close();
      final second = session.close();
      await eventually(() => held != null);
      reply(held!, error: {
        'code': -32000,
        'message': 'There was a problem with the datastore',
        'kind': 'Internal',
      });
      await expectLater(first, throwsA(isA<ServerError>()));
      await expectLater(second, throwsA(isA<ServerError>()));
      expect(session.isClosed, isFalse);
      expect(server.methods.where((m) => m == 'detach'), hasLength(1));
    });

    test('a fork that fails and cannot be detached is not kept', () async {
      await db.set('x', 1);
      server.handler = (r) => switch (r.method) {
            'let' =>
              const FakeError('Bad variable', extra: {'kind': 'Validation'}),
            'detach' => const FakeError(
                'There was a problem with the datastore',
                extra: {'kind': 'Internal'}),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await expectLater(db.forkSession(), throwsA(isA<ValidationError>()));
      final fork = last('attach').raw['session'];
      server.handler = FakeSurrealServer.defaultReply;
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(
          server.requests
              .where((r) => r.method == 'attach' && r.raw['session'] == fork),
          isEmpty);
    });

    test('a call that completes while detach is refused keeps its effect',
        () async {
      final session = await db.newSession();
      final held = <String, FakeRequest>{};
      server.handler = (r) {
        if (r.method == 'let' || r.method == 'detach') {
          held[r.method] = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final setting = session.set('x', 1);
      final closing = session.close();
      await eventually(() => held.length == 2);
      reply(held['let']!);
      await setting;
      reply(held['detach']!, error: {
        'code': -32000,
        'message': 'There was a problem with the datastore',
        'kind': 'Internal',
      });
      await expectLater(closing, throwsA(isA<ServerError>()));
      server.handler = FakeSurrealServer.defaultReply;
      server.requests.clear();

      await server.dropAll();
      await eventually(() => server.requests
          .any((r) => r.method == 'let' && r.raw['session'] == session.id));
      expect(last('let').params, ['x', 1]);
    });

    test('a timed out begin starts again on a new socket', () async {
      final timed = Surreal();
      addTearDown(timed.close);
      await timed.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            requestTimeout: Duration(milliseconds: 300),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      final before = server.accepted;
      server.handler = (r) => r.method == 'begin'
          ? const FakeSilence()
          : FakeSurrealServer.defaultReply(r);
      await expectLater(
          timed.beginTransaction(), throwsA(isA<RequestTimeoutError>()));
      await eventually(() =>
          server.accepted == before + 1 &&
          timed.status == ConnectionStatus.connected);
    });

    test('closing the client closes its sessions', () async {
      final session = await db.newSession();
      await db.close();
      expect(session.isClosed, isTrue);
      expect(() => session.beginTransaction(),
          throwsA(isA<InvalidSessionError>()));
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
