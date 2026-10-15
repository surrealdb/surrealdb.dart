@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('lifecycle', () {
    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      test('a client can connect again after close over $engine', () async {
        final db = await connectRoot(url);
        await db.close();
        expect(db.status, ConnectionStatus.disconnected);

        await db.connect(url);
        await db.signin(const RootAuth(username: 'root', password: 'root'));
        await db.use(namespace: 'test', database: 'test');
        final results = await db.query('RETURN 1 + 1');
        expect(results.single, 2);
        await db.health();
        await db.close();
      });

      test('connect replaces an open connection over $engine', () async {
        final db = await connectRoot(url);
        await db.connect(url);
        await db.signin(const RootAuth(username: 'root', password: 'root'));
        expect((await db.query('RETURN true')).single, isTrue);
        await db.close();
      });
    }

    test('status changes survive a reconnect', () async {
      final db = Surreal();
      final statuses = <ConnectionStatus>[];
      final subscription = db.statusChanges.listen(statuses.add);

      await db.connect(wsUrl);
      await db.close();
      await db.connect(wsUrl);
      await db.close();
      await Future<void>.delayed(Duration.zero);

      expect(
        statuses.where((s) => s == ConnectionStatus.connected).length,
        2,
      );
      await subscription.cancel();
    });
  }, skip: skipIntegration);
}
