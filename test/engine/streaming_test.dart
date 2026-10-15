@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  const frames = [
    {'stream': 'begin', 'version': 1, 'statements': 3},
    {
      'stream': 'rows',
      'index': 0,
      'values': [1, 2],
    },
    {
      'stream': 'rows',
      'index': 0,
      'values': [3],
    },
    {'stream': 'finished', 'index': 0, 'single': false, 'time': '1ms'},
    {'stream': 'value', 'index': 1, 'value': 'x'},
    {'stream': 'finished', 'index': 1, 'single': true, 'time': '1ms'},
    {
      'stream': 'finished',
      'index': 2,
      'single': false,
      'error': {'code': -32006, 'message': 'boom', 'kind': 'Thrown'},
    },
    {'stream': 'end', 'results': 3, 'time': '3ms'},
  ];

  Future<void> connect(String version) async {
    server.handler = (r) => switch (r.method) {
          'version' => FakeResult(version),
          'query_stream' => const FakeResults(frames),
          _ => FakeSurrealServer.defaultReply(r),
        };
    await db.connect(server.url);
  }

  setUp(() async {
    server = await FakeSurrealServer.start();
    db = Surreal();
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('turns stream replies into frames', () async {
    await connect('surrealdb-3.3.4');
    final received = await db.queryStream('q').toList();
    expect(server.methods.last, 'query_stream');
    expect(received, hasLength(6));
    expect(received[0],
        isA<QueryRows>().having((f) => f.values, 'values', [1, 2]));
    expect(
        received[1], isA<QueryRows>().having((f) => f.values, 'values', [3]));
    expect(
        received[2],
        isA<QueryStatementDone>()
            .having((f) => f.statement, 'statement', 0)
            .having((f) => f.ok, 'ok', isTrue));
    expect(received[3], isA<QueryValue>().having((f) => f.value, 'value', 'x'));
    expect(received[4],
        isA<QueryStatementDone>().having((f) => f.single, 'single', isTrue));
    expect(
        received[5],
        isA<QueryStatementDone>()
            .having((f) => f.error, 'error', isA<ThrownError>())
            .having((f) => f.error?.statementIndex, 'statementIndex', 2));
  });

  test('cancelling the stream cancels the query on the server', () async {
    await connect('surrealdb-3.3.4');
    server.handler = (r) => switch (r.method) {
          // Never sends the end, as a long query would not yet.
          'query_stream' => FakeResults(frames.sublist(0, 2)),
          _ => FakeSurrealServer.defaultReply(r),
        };
    final first = await db.queryStream('SELECT * FROM big').first;
    expect(first, isA<QueryRows>());
    final requestId =
        server.requests.lastWhere((r) => r.method == 'query_stream').id;
    await eventually(() => server.methods.contains('query_cancel'));
    expect(server.requests.last.params, [requestId]);
  });

  test('falls back to a buffered query before 3.3', () async {
    await connect('surrealdb-3.2.0');
    server.handler = (r) => r.method == 'query'
        ? const FakeResult([
            {
              'status': 'OK',
              'time': '1ms',
              'result': [1, 2]
            },
            {'status': 'OK', 'time': '1ms', 'result': 'x'},
            {
              'status': 'ERR',
              'time': '1ms',
              'result': 'boom',
              'kind': 'Thrown'
            },
          ])
        : FakeSurrealServer.defaultReply(r);
    final received = await db.queryStream('q').toList();
    expect(server.methods, isNot(contains('query_stream')));
    expect(received.map((f) => f.runtimeType), [
      QueryRows,
      QueryStatementDone,
      QueryValue,
      QueryStatementDone,
      QueryStatementDone,
    ]);
    expect((received.last as QueryStatementDone).error, isA<ThrownError>());
  });

  test('falls back, and remembers, when the server refuses to stream',
      () async {
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
    server.handler = (r) => switch (r.method) {
          'query_stream' => const FakeError('Method not found', code: -32601),
          'query' => const FakeResult([
              {'status': 'OK', 'time': '1ms', 'result': 1},
            ]),
          _ => FakeSurrealServer.defaultReply(r),
        };
    expect(await db.queryStream('q').toList(), hasLength(2));
    expect(await db.queryStream('q').toList(), hasLength(2));
    expect(server.methods.where((m) => m == 'query_stream'), hasLength(1));
    expect(server.methods.where((m) => m == 'query'), hasLength(2));
  });

  test('falls back when the capabilities deny streaming', () async {
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
    server.handler = (r) => switch (r.method) {
          'query_stream' =>
            const FakeError('Method not allowed', code: -32602, extra: {
              'kind': 'NotAllowed',
              'details': {
                'kind': 'Method',
                'details': {'name': 'query_stream'},
              },
            }),
          'query' => const FakeResult([
              {'status': 'OK', 'time': '1ms', 'result': 1},
            ]),
          _ => FakeSurrealServer.defaultReply(r),
        };
    expect(await db.queryStream('q').toList(), hasLength(2));
    expect(server.methods.where((m) => m == 'query_stream'), hasLength(1));
  });

  test('a failed query fails the stream', () async {
    await connect('surrealdb-3.3.4');
    server.handler = (r) => r.method == 'query_stream'
        ? const FakeError('Parse error', extra: {'kind': 'Validation'})
        : FakeSurrealServer.defaultReply(r);
    await expectLater(
        db.queryStream('nonsense').toList(), throwsA(isA<ValidationError>()));
  });

  test('streams inside a transaction carry its id', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await connect('surrealdb-3.3.4');
    server.handler = (r) => switch (r.method) {
          'begin' => FakeResult(txn),
          'query_stream' => const FakeResults(frames),
          _ => FakeSurrealServer.defaultReply(r),
        };
    final transaction = await db.beginTransaction();
    await transaction.queryStream('q').drain<void>();
    expect(server.requests.last.raw['txn'], txn);
  });
}
