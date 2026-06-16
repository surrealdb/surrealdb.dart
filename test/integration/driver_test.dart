@TestOn('vm')
library;

import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

/// These tests need a running SurrealDB instance. They only run when the
/// SURREAL_INTEGRATION environment variable is set, so the default
/// `dart test` run stays green without a server.
///
/// Start a server with:
///   surreal start --user root --pass root memory
/// then run:
///   SURREAL_INTEGRATION=1 dart test test/integration
void main() {
  final enabled = Platform.environment['SURREAL_INTEGRATION'] == '1';
  final wsUrl =
      Platform.environment['SURREAL_WS_URL'] ?? 'ws://127.0.0.1:8000/rpc';
  final httpUrl =
      Platform.environment['SURREAL_HTTP_URL'] ?? 'http://127.0.0.1:8000/rpc';

  group('WebSocket engine', () {
    late Surreal db;

    setUp(() async {
      db = Surreal();
      await db.connect(wsUrl);
      await db.signin(const RootAuth(username: 'root', password: 'root'));
      await db.query('DEFINE NAMESPACE IF NOT EXISTS test; '
          'USE NS test; DEFINE DATABASE IF NOT EXISTS test;');
      await db.use(namespace: 'test', database: 'test');
      await db.query('REMOVE TABLE IF EXISTS person');
    });

    tearDown(() async {
      await db.query('REMOVE TABLE IF EXISTS person');
      await db.close();
    });

    test('create and select a record', () async {
      final created = await db.create(
        const RecordId('person', 'tobie'),
        {'name': 'Tobie'},
      ) as Map<String, dynamic>;
      expect(created['name'], 'Tobie');

      final selected = await db.select(const RecordId('person', 'tobie'))
          as Map<String, dynamic>;
      expect(selected['name'], 'Tobie');
    });

    test('merge and delete', () async {
      await db.create(const RecordId('person', 'jaime'), {'name': 'Jaime'});
      await db.merge(const RecordId('person', 'jaime'), {'age': 30});
      final merged = await db.select(const RecordId('person', 'jaime'))
          as Map<String, dynamic>;
      expect(merged['age'], 30);

      await db.delete(const RecordId('person', 'jaime'));
      final gone = await db.select(const RecordId('person', 'jaime'));
      expect(gone, isNull);
    });

    test('query with bindings', () async {
      await db.create(const RecordId('person', 'a'), {'age': 20});
      await db.create(const RecordId('person', 'b'), {'age': 40});
      final results = await db.query(
        r'SELECT * FROM person WHERE age > $min',
        bindings: {'min': 30},
      );
      final rows = results.first as List;
      expect(rows.length, 1);
    });

    test('live query receives a create notification', () async {
      await db.query('DEFINE TABLE IF NOT EXISTS person');
      final live = await db.live('person');
      final received = live.stream.first;

      await db.create(const RecordId('person', 'live'), {'name': 'Live'});

      final message = await received.timeout(const Duration(seconds: 5));
      expect(message.action, LiveAction.create);

      await live.kill();
    });

    test('export returns SurrealQL', () async {
      await db.create(const RecordId('person', 'export'), {'name': 'Export'});
      final dump = await db.export();
      expect(dump, contains('person'));
    });
  }, skip: enabled ? false : 'set SURREAL_INTEGRATION=1 to run');

  group('HTTP engine', () {
    late Surreal db;

    setUp(() async {
      db = Surreal();
      await db.connect(httpUrl);
      await db.signin(const RootAuth(username: 'root', password: 'root'));
      await db.query('DEFINE NAMESPACE IF NOT EXISTS test; '
          'USE NS test; DEFINE DATABASE IF NOT EXISTS test;');
      await db.use(namespace: 'test', database: 'test');
      await db.query('REMOVE TABLE IF EXISTS gadget');
    });

    tearDown(() async {
      await db.query('REMOVE TABLE IF EXISTS gadget');
      await db.close();
    });

    test('create and select over HTTP', () async {
      await db.create(const RecordId('gadget', 'one'), {'name': 'Widget'});
      final selected = await db.select(const RecordId('gadget', 'one'))
          as Map<String, dynamic>;
      expect(selected['name'], 'Widget');
    });

    test('live queries are unsupported over HTTP', () async {
      expect(
        () => db.live('gadget'),
        throwsA(isA<UnsupportedFeatureError>()),
      );
    });
  }, skip: enabled ? false : 'set SURREAL_INTEGRATION=1 to run');

  group('WebSocket engine with the JSON format', () {
    late Surreal db;

    setUp(() async {
      db = Surreal();
      await db.connect(wsUrl,
          options: const ConnectOptions(format: SurrealFormat.json));
      await db.signin(const RootAuth(username: 'root', password: 'root'));
      await db.query('DEFINE NAMESPACE IF NOT EXISTS test; '
          'USE NS test; DEFINE DATABASE IF NOT EXISTS test;');
      await db.use(namespace: 'test', database: 'test');
      await db.query('REMOVE TABLE IF EXISTS widget');
    });

    tearDown(() async {
      await db.query('REMOVE TABLE IF EXISTS widget');
      await db.close();
    });

    test('create and select over JSON', () async {
      await db.create(const RecordId('widget', 'one'), {'name': 'Sprocket'});
      final selected = await db.select(const RecordId('widget', 'one'))
          as Map<String, dynamic>;
      expect(selected['name'], 'Sprocket');
    });

    test('live query works over JSON', () async {
      await db.query('DEFINE TABLE IF NOT EXISTS widget');
      final live = await db.live('widget');
      final received = live.stream.first;

      await db.create(const RecordId('widget', 'live'), {'name': 'Live'});

      final message = await received.timeout(const Duration(seconds: 5));
      expect(message.action, LiveAction.create);

      await live.kill();
    });
  }, skip: enabled ? false : 'set SURREAL_INTEGRATION=1 to run');
}
