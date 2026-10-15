@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

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

  test('variables set with set() are replayed after a reconnect', () async {
    await db.use(namespace: 'ns', database: 'db');
    await db.set('kept', {'a': 1});
    await db.set('removed', 2);
    await db.unset('removed');
    server.requests.clear();

    await server.dropAll();
    await eventually(
        () => db.status == ConnectionStatus.connected && server.accepted == 2);

    final replayed = [
      for (final r in server.requests) [r.method, ...r.params],
    ];
    expect(replayed, [
      ['use', 'ns', 'db'],
      [
        'let',
        'kept',
        {'a': 1},
      ],
    ]);
  });

  test('a replayed variable keeps the value that was sent', () async {
    final value = {
      'list': [1],
      'nested': {'a': 1},
    };
    await db.set('kept', value);
    (value['list']! as List).add(2);
    (value['nested']! as Map)['a'] = 2;
    value['extra'] = 3;
    server.requests.clear();

    await server.dropAll();
    await eventually(
        () => db.status == ConnectionStatus.connected && server.accepted == 2);

    final let = server.requests.singleWhere((r) => r.method == 'let');
    expect(let.params, [
      'kept',
      {
        'list': [1],
        'nested': {'a': 1},
      },
    ]);
  });

  test('a variable changed while set() is in flight replays as sent', () async {
    final value = {'n': 1};
    final bytes = Uint8List.fromList(List.filled(16, 1));
    final setting = db.set('kept', value);
    final settingId = db.set('id', Uuid.fromBytes(bytes));
    value['n'] = 2;
    bytes[0] = 9;
    await setting;
    await settingId;
    server.requests.clear();

    await server.dropAll();
    await eventually(
        () => db.status == ConnectionStatus.connected && server.accepted == 2);

    final lets = {
      for (final r in server.requests.where((r) => r.method == 'let'))
        r.params[0]: r.params[1],
    };
    expect(lets['kept'], {'n': 1});
    expect(lets['id'], Uuid.fromBytes(Uint8List.fromList(List.filled(16, 1))));
  });
}
