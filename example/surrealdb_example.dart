// ignore_for_file: avoid_print
// Run a local server first:
//   surreal start --user root --pass root memory
// then:
//   dart run example/surrealdb_example.dart
import 'package:surrealdb/surrealdb.dart';

Future<void> main() async {
  final db = Surreal();

  await db.connect('ws://127.0.0.1:8000/rpc');
  await db.signin(const RootAuth(username: 'root', password: 'root'));

  // A fresh server has no namespace or database yet, so define them. An
  // existing deployment usually has these set up already.
  await db.query('DEFINE NAMESPACE IF NOT EXISTS test; '
      'USE NS test; DEFINE DATABASE IF NOT EXISTS test;');
  await db.use(namespace: 'test', database: 'test');

  // Create a record with an explicit id.
  final tobie = await db.create(
    const RecordId('person', 'tobie'),
    {'name': 'Tobie', 'admin': true},
  );
  print('created: $tobie');

  // Create a record with a generated id by targeting the table.
  await db.create('person', {'name': 'Jaime'});

  // Merge a partial update.
  await db.merge(const RecordId('person', 'tobie'), {'age': 32});

  // Run a query with bound parameters.
  final results = await db.query(
    r'SELECT name, age FROM person WHERE admin = $admin',
    bindings: {'admin': true},
  );
  print('admins: ${results.first}');

  // Start a live query and react to changes.
  final live = await db.live('person');
  final subscription = live.stream.listen((message) {
    print('live ${message.action.name}: ${message.value}');
  });

  await db.create('person', {'name': 'Lizzie'});
  await Future<void>.delayed(const Duration(milliseconds: 500));

  await subscription.cancel();
  await live.kill();
  await db.close();
}
