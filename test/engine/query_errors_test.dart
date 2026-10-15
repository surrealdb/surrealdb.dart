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
    db = Surreal();
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  Map<String, Object?> failed(String detail) => {
        'status': 'ERR',
        'time': '1ms',
        'result': detail,
        'kind': 'Query',
        'details': {'kind': detail},
      };

  test('a failed transaction throws its cause, not a statement left out',
      () async {
    server.handler = (r) => r.method == 'query'
        ? FakeResult([
            failed('NotExecuted'),
            failed('NotExecuted'),
            failed('TransactionConflict'),
          ])
        : FakeSurrealServer.defaultReply(r);
    await expectLater(
      db.query('BEGIN; CREATE a; CREATE b; COMMIT;'),
      throwsA(isA<QueryError>()
          .having(
              (e) => e.isTransactionConflict, 'isTransactionConflict', isTrue)
          .having((e) => e.statementIndex, 'statementIndex', 2)),
    );
  });

  test('statements that were only not executed throw the first', () async {
    server.handler = (r) => r.method == 'query'
        ? FakeResult([failed('NotExecuted'), failed('NotExecuted')])
        : FakeSurrealServer.defaultReply(r);
    await expectLater(
      db.query('q'),
      throwsA(isA<QueryError>()
          .having((e) => e.statementIndex, 'statementIndex', 0)),
    );
  });
}
