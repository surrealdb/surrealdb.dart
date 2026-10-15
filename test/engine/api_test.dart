@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  setUp(() async {
    server = await FakeSurrealServer.start();
    server.handler = (r) => r.method == 'query'
        ? const FakeResult([
            {
              'status': 'OK',
              'time': '1ms',
              'result': {'status': 200},
            },
          ])
        : FakeSurrealServer.defaultReply(r);
    db = Surreal();
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  Map<Object?, Object?> sentHeaders() {
    final bindings = server.requests.last.params[1] as Map;
    return (bindings['request'] as Map)['headers'] as Map;
  }

  test('header names are not case sensitive', () async {
    await db.api
        .header('Authorization', 'secret')
        .header('authorization', null)
        .get('/x');
    expect(sentHeaders(), isEmpty);

    await db.api.header('X-Tenant', 'a').get('/x', headers: {'x-TENANT': 'b'});
    expect(sentHeaders(), {'x-tenant': 'b'});
  });
}
