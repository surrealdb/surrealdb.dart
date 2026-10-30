@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  const fastReconnect = ReconnectOptions(
    attempts: 3,
    retryDelay: Duration(milliseconds: 10),
    retryDelayMax: Duration(milliseconds: 10),
  );

  setUp(() async {
    server = await FakeSurrealServer.start();
    db = Surreal();
    await db.connect(server.url,
        options: const ConnectOptions(reconnect: fastReconnect));
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('one failed restart does not drop the other live queries', () async {
    final failing = await db.live('broken');
    final healthy = await db.live('person');
    final healthyBefore = healthy.id;
    final errors = <Object>[];
    failing.stream.listen(null, onError: errors.add);

    server.handler = (request) => request.method == 'live' &&
            request.params.first == const Table('broken')
        ? const FakeError('Permission denied')
        : FakeSurrealServer.defaultReply(request);
    await server.dropAll();
    await eventually(() => healthy.id != healthyBefore);

    // The healthy query was restarted and still receives notifications.
    final received = healthy.stream.first;
    server.push({
      'result': {
        'id': healthy.id,
        'action': 'CREATE',
        'result': {'id': const RecordId('person', 1)},
      },
    });
    expect((await received).action, LiveAction.create);

    // The failing query was told, and is tried again on the next reconnect.
    await eventually(() => errors.isNotEmpty);
    server.handler = FakeSurrealServer.defaultReply;
    final failingBefore = failing.id;
    await server.dropAll();
    await eventually(() => failing.id != failingBefore);
  });

  test('liveOf needs a live connection', () async {
    final offline = Surreal();
    addTearDown(offline.close);
    await offline.connect(server.url,
        options:
            const ConnectOptions(reconnect: ReconnectOptions(enabled: false)));
    await server.dropAll();
    await eventually(() => offline.status == ConnectionStatus.disconnected);
    expect(() => offline.liveOf(Uuid.v4()),
        throwsA(isA<ConnectionUnavailableError>()));
  });
}
