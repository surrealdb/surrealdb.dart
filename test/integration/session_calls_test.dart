@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('session calls', () {
    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async => db = await connectRoot(url));
        tearDown(() async => db.close());

        test('use can clear the database', () async {
          await db.use(database: null);
          expect(db.namespace, 'test');
          expect(db.database, isNull);
          final [ns, database] =
              await db.query('RETURN session::ns(); RETURN session::db();');
          expect(ns, 'test');
          expect(database, anyOf(isNull, same(none)));
        });

        test('set and unset apply to later queries', () async {
          await db.set('answer', 42);
          expect((await db.query(r'RETURN $answer')).single, 42);
          // A binding in the call itself wins.
          expect(
            (await db.query(r'RETURN $answer', bindings: {'answer': 1})).single,
            1,
          );
          await db.unset('answer');
          expect((await db.query(r'RETURN $answer')).single, same(none));
        });

        test('reset signs out and clears the session', () async {
          await db.set('answer', 42);
          await db.reset();
          expect(db.namespace, isNull);
          expect(db.database, isNull);
          expect(db.accessToken, isNull);
          await db.signin(const RootAuth(username: 'root', password: 'root'));
          await db.use(namespace: 'test', database: 'test');
          expect((await db.query(r'RETURN $answer')).single, same(none));
        });
      });
    }

    test('liveOf attaches to a live query started in a query', () async {
      final db = await connectRoot(wsUrl);
      addTearDown(db.close);
      await db.query('DEFINE TABLE IF NOT EXISTS watched');
      final [id] = await db.query('LIVE SELECT * FROM watched');
      final live = db.liveOf(id! as Uuid);
      final received = live.stream.first;

      await db.query('CREATE watched:1');
      final message = await received.timeout(const Duration(seconds: 5));
      expect(message.action, LiveAction.create);
      expect(message.recordId, const RecordId('watched', 1));

      await live.kill();
      await db.query('REMOVE TABLE watched');
    });
  }, skip: skipIntegration);
}
