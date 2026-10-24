@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('query streaming', () {
    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async {
          db = await connectRoot(url);
          await db.query('REMOVE TABLE IF EXISTS stream_row; '
              'DEFINE TABLE stream_row; '
              'FOR \$i IN 1..=600 { CREATE stream_row:[\$i] SET n = \$i };');
        });
        tearDown(() async {
          await db.query('REMOVE TABLE IF EXISTS stream_row');
          await db.close();
        });

        test('gives the same results as query', () async {
          const q = 'SELECT VALUE n FROM stream_row ORDER BY n; RETURN 5; '
              'THROW "x"; SELECT * FROM stream_row WHERE n > 1000;';
          final frames = await db.queryStream(q).toList();

          final rows = [
            for (final f in frames)
              if (f is QueryRows && f.statement == 0) ...f.values,
          ];
          expect(rows, [for (var i = 1; i <= 600; i++) i]);
          expect(
            frames.whereType<QueryValue>().single,
            isA<QueryValue>()
                .having((f) => f.statement, 'statement', 1)
                .having((f) => f.value, 'value', 5),
          );
          final done = frames.whereType<QueryStatementDone>().toList();
          expect(done.map((f) => f.statement), [0, 1, 2, 3]);
          expect(done[2].error, isA<ThrownError>());
          expect(done.where((f) => f.ok), hasLength(3));
          expect(frames.whereType<QueryRows>().where((f) => f.statement == 3),
              isEmpty);
        });
      });
    }

    test('large results arrive in several batches over WebSocket', () async {
      // Servers before 3.3 answer a streamed query with one batch.
      if (!await serverAtLeast(3, 3)) return markTestSkipped('needs 3.3');
      final db = await connectRoot(wsUrl);
      addTearDown(db.close);
      await db.query('REMOVE TABLE IF EXISTS stream_batch; '
          'FOR \$i IN 1..=600 { CREATE stream_batch; };');
      final batches = await db
          .queryStream('SELECT * FROM stream_batch')
          .where((f) => f is QueryRows)
          .map((f) => (f as QueryRows).values.length)
          .toList();
      expect(batches.length, greaterThan(1));
      expect(batches.fold<int>(0, (a, b) => a + b), 600);
      await db.query('REMOVE TABLE stream_batch');
    });

    test('cancelling a stream leaves the connection usable', () async {
      final db = await connectRoot(wsUrl);
      addTearDown(db.close);
      final first = await db
          .queryStream(r'FOR $i IN 1..=2000 { CREATE stream_cancel; }; '
              'SELECT * FROM stream_cancel;')
          .first;
      expect(first, isA<QueryFrame>());
      expect((await db.query('RETURN 1')).single, 1);
      await db.query('REMOVE TABLE IF EXISTS stream_cancel');
    });

    test('streams inside a transaction', () async {
      final db = await connectRoot(wsUrl);
      addTearDown(db.close);
      final txn = await db.beginTransaction();
      final frames = await txn.queryStream('RETURN 1; RETURN 2;').toList();
      expect(frames.whereType<QueryValue>().map((f) => f.value), [1, 2]);
      await txn.commit();
    });
  }, skip: skipIntegration);
}
