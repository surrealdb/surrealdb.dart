@TestOn('vm')
library;

import 'dart:convert';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

/// An unsigned JWT with [claims], as the server's tokens carry them.
String jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.';
}

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  setUp(() async {
    server = await FakeSurrealServer.start();
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

  List<Object?> lastParams(String method) =>
      server.requests.lastWhere((r) => r.method == method).params;

  group('use', () {
    test('a namespace that was never known is kept after a reconnect',
        () async {
      // An older server that does not say what it selected.
      server.handler = (r) => r.method == 'use'
          ? const FakeResult(null)
          : FakeSurrealServer.defaultReply(r);
      await db.authenticate('token');
      await db.use(database: 'db');
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['authenticate', 'use']);
      expect(lastParams('use'), [none, 'db']);
    });

    test('a cleared selection is cleared again after authenticating', () async {
      await db.authenticate('token');
      await db.use(namespace: 'ns', database: 'db');
      await db.use(namespace: null);
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['authenticate', 'use']);
      expect(lastParams('use'), [null, null]);
    });

    test('a cleared database is cleared again after authenticating', () async {
      await db.authenticate('token');
      await db.use(namespace: 'ns', database: 'db');
      await db.use(database: null);
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['use', 'authenticate', 'use']);
      expect(lastParams('use'), ['ns', null]);
    });

    test('a cleared database is cleared again in a namespace never known',
        () async {
      server.handler = (r) => r.method == 'use'
          ? const FakeResult(null)
          : FakeSurrealServer.defaultReply(r);
      await db.authenticate('token');
      await db.use(database: null);
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['authenticate', 'use']);
      expect(lastParams('use'), [none, null]);
    });

    test('signing in selects what the token names', () async {
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(jwt({'NS': 'ns', 'DB': 'db', 'ID': 'u'}))
          : FakeSurrealServer.defaultReply(r);
      await db.use(namespace: 'other', database: 'x');
      await db.use(namespace: null);
      await db.signin(const DatabaseAuth(
          namespace: 'ns', database: 'db', username: 'u', password: 'p'));
      expect([db.namespace, db.database], ['ns', 'db']);
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['use', 'authenticate']);
      expect(lastParams('use'), ['ns', 'db']);
    });

    test('authenticating selects what the token names', () async {
      await db.use(namespace: 'a', database: 'b');
      await db.authenticate(jwt({'NS': 'ns', 'ID': 'u'}));
      expect([db.namespace, db.database], ['ns', 'b']);
    });

    test('a selection made after authenticating wins on a reconnect', () async {
      await db.authenticate(jwt({'NS': 'ns', 'ID': 'u'}));
      await db.use(namespace: 'other', database: 'db');
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['use', 'authenticate', 'use']);
      expect(lastParams('use'), ['other', 'db']);
      expect([db.namespace, db.database], ['other', 'db']);
    });

    test('a new connection starts with nothing known, not cleared', () async {
      await db.use(namespace: null);
      await db.close();
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      server.handler = (r) => r.method == 'use'
          ? const FakeResult(null)
          : FakeSurrealServer.defaultReply(r);
      await db.authenticate('token');
      await db.use(database: 'db');
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 3);
      expect(lastParams('use'), [none, 'db']);
    });

    test('a cleared namespace is cleared again after a reconnect', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.use(namespace: null);
      await db.use(namespace: 'other');
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(lastParams('use'), ['other', null]);
    });

    test('sends NONE for a value it does not know, to keep it', () async {
      await db.use(database: 'db');
      expect(lastParams('use'), [none, 'db']);
    });

    test('sends a known value as it is, to keep it', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.use(database: 'other');
      expect(lastParams('use'), ['ns', 'other']);
      expect(db.namespace, 'ns');
      expect(db.database, 'other');
    });

    test('null clears a value', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.use(database: null);
      expect(lastParams('use'), ['ns', null]);
      expect(db.database, isNull);
    });

    test('clearing the namespace clears the database', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.use(namespace: null);
      expect(lastParams('use'), [null, null]);
      expect(db.namespace, isNull);
      expect(db.database, isNull);
    });

    test('a database cannot be selected while clearing the namespace',
        () async {
      expect(() => db.use(namespace: null, database: 'db'),
          throwsA(isA<MissingNamespaceDatabaseError>()));
    });

    test('the server reply wins', () async {
      server.handler = (request) => request.method == 'use'
          ? const FakeResult({'namespace': 'defaultns', 'database': none})
          : FakeSurrealServer.defaultReply(request);
      await db.use();
      expect(db.namespace, 'defaultns');
      expect(db.database, isNull);
    });

    test('a cleared value is not replayed after a reconnect', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.use(database: null);
      server.requests.clear();
      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(lastParams('use'), ['ns', null]);
    });
  });

  group('reset', () {
    test('forgets the session and closes live queries', () async {
      await db.use(namespace: 'ns', database: 'db');
      await db.authenticate('token');
      await db.set('x', 1);
      final live = await db.live('person');
      var closed = false;
      live.stream.listen(null, onDone: () => closed = true);

      await db.reset();

      expect(server.methods.last, 'reset');
      expect(db.namespace, isNull);
      expect(db.database, isNull);
      expect(db.accessToken, isNull);
      await eventually(() => closed);

      // Nothing is replayed after a reconnect.
      server.requests.clear();
      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.methods, isEmpty);
    });
  });

  group('liveOf', () {
    final id = Uuid('01234567-89ab-4def-8123-456789abcdef');

    test('delivers notifications for an existing live query', () async {
      final live = db.liveOf(id);
      final received = live.stream.first;
      server.push({
        'result': {
          'id': id,
          'action': 'CREATE',
          'record': const RecordId('person', 1),
          'result': {'id': const RecordId('person', 1)},
        },
      });
      expect((await received).recordId, const RecordId('person', 1));
      await live.kill();
      expect(lastParams('kill'), [id]);
    });

    test('reports the query as lost after a reconnect', () async {
      final live = db.liveOf(id);
      final errors = <Object>[];
      var closed = false;
      live.stream
          .listen(null, onError: errors.add, onDone: () => closed = true);

      await server.dropAll();
      await eventually(() => closed);
      expect(errors.single, isA<LiveQueryLostError>());
      expect(server.methods, isNot(contains('live')));
    });

    test('reset does not wait for a paused listener', () async {
      final live = await db.live('person');
      final subscription = live.stream.listen(null, onError: (_) {});
      subscription.pause();
      await db.reset().timeout(const Duration(seconds: 2));
      await subscription.cancel();
    });

    test('a paused listener does not hold up the other restarts', () async {
      final attached = db.liveOf(id);
      final subscription = attached.stream.listen(null, onError: (_) {});
      subscription.pause();
      final own = await db.live('person');
      final before = own.id;

      await server.dropAll();
      await eventually(() => own.id != before);
      expect(db.status, ConnectionStatus.connected);
      await subscription.cancel();
    });
  });
}
