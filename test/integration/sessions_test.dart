@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('sessions', () {
    late Surreal db;

    setUp(() async {
      db = await connectRoot(wsUrl);
      await db.query('DEFINE DATABASE IF NOT EXISTS other');
    });
    tearDown(() async => db.close());

    test('a new session has its own state', () async {
      final session = await db.newSession();
      await session.signin(const RootAuth(username: 'root', password: 'root'));
      await session.use(namespace: 'test', database: 'other');
      final [sessionDb] = await session.query('RETURN session::db()');
      final [defaultDb] = await db.query('RETURN session::db()');
      expect(sessionDb, 'other');
      expect(defaultDb, 'test');
      await session.close();
    });

    test('sessions are listed until closed', () async {
      final session = await db.newSession();
      expect(await db.sessions(), contains(session.id));
      await session.close();
      expect(await db.sessions(), isNot(contains(session.id)));
    });

    test('a fork copies authentication, database and variables', () async {
      await db.set('greeting', 'hello');
      final fork = await db.forkSession();
      final [greeting, database, root] = await fork
          .query(r'RETURN $greeting; RETURN session::db(); INFO FOR ROOT;');
      expect(greeting, 'hello');
      expect(database, 'test');
      // Only a root user can read the root info, so the fork signed in.
      expect(root, isA<Map<String, Object?>>());
      expect(fork.accessToken, db.accessToken);

      await fork.set('greeting', 'changed');
      expect((await db.query(r'RETURN $greeting')).single, 'hello');
      await fork.close();
    });

    test('live queries run in their session', () async {
      final session = await db.forkSession();
      await session.query('DEFINE TABLE IF NOT EXISTS session_live');
      final live = await session.live('session_live');
      final received = live.stream.first;
      await db.query('CREATE session_live:1');
      final message = await received.timeout(const Duration(seconds: 5));
      expect(message.recordId, const RecordId('session_live', 1));
      await live.kill();
      await session.close();
      await db.query('REMOVE TABLE session_live');
    });
  }, skip: skipIntegration);

  group('transactions', () {
    late Surreal db;
    late SurrealSession observer;

    setUp(() async {
      db = await connectRoot(wsUrl);
      await db.query('DEFINE TABLE IF NOT EXISTS ledger; DELETE ledger;');
      observer = await db.forkSession();
    });
    tearDown(() async {
      await db.query('REMOVE TABLE IF EXISTS ledger');
      await db.close();
    });

    Future<List<Object?>> seen() async =>
        (await observer.query('SELECT * FROM ledger')).single! as List<Object?>;

    test('changes are visible to others only after commit', () async {
      final txn = await db.beginTransaction();
      await txn.create(const RecordId('ledger', 1), {'amount': 10});
      await txn.query('CREATE ledger:2 SET amount = 20');
      final [inside] = await txn.query('SELECT * FROM ledger');
      expect(inside, hasLength(2));
      expect(await seen(), isEmpty);

      await txn.commit();
      expect(await seen(), hasLength(2));
    });

    test('cancel discards every change', () async {
      final txn = await db.beginTransaction();
      await txn.create(const RecordId('ledger', 1), {'amount': 10});
      await txn.cancel();
      expect(await seen(), isEmpty);
    });

    test('a transaction can run in an attached session', () async {
      final txn = await observer.beginTransaction();
      await txn.create(const RecordId('ledger', 3), {'amount': 30});
      expect((await db.query('SELECT * FROM ledger')).single, isEmpty);
      await txn.commit();
      expect((await db.query('SELECT * FROM ledger')).single, hasLength(1));
    });
  }, skip: skipIntegration);

  group('over HTTP', () {
    late Surreal db;

    setUp(() async => db = await connectRoot(httpUrl));
    tearDown(() async => db.close());

    test('sessions and transactions are not supported', () async {
      expect(() => db.newSession(), throwsA(isA<UnsupportedFeatureError>()));
      expect(() => db.sessions(), throwsA(isA<UnsupportedFeatureError>()));
      expect(
          () => db.beginTransaction(), throwsA(isA<UnsupportedFeatureError>()));
    });
  }, skip: skipIntegration);
}
